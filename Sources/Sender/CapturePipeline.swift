import Foundation
import ScreenCaptureKit
import VideoToolbox

// Flujo y encoder serializados en queue; configuración y callbacks de UI en main.
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Frame { let image: CVPixelBuffer; let pts: CMTime; let capturedAt: Double }
    private let queue = DispatchQueue(label: "imac.capture", qos: .userInteractive)
    private var flow: FrameFlow<Frame>
    private var statistics = RecentVideoMetrics(now: ProcessInfo.processInfo.systemUptime)
    private var stopped = false
    private var lastEncoded: UInt32 = 0
    private var encoder: VTCompressionSession?
    private var stream: SCStream?
    private var sourceDisplayID: CGDirectDisplayID = 0
    @MainActor var onFrame: ((Data, UInt32) -> Void)?
    @MainActor var onError: ((String) -> Void)?

    init(window: Int = 3) { flow = FrameFlow(capacity: window); super.init() }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitrate: Int) async throws {
        Diagnostics.shared.event("capture_discovery_started")
        sourceDisplayID = displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              CGDisplayIsInMirrorSet(displayID) == 0 else { throw DisplayError("No se encontró la pantalla virtual independiente para capturar.") }
        Diagnostics.shared.event("capture_display_found")
        try configureEncoder(width: width, height: height, fps: fps, bitrate: bitrate)
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        // Tres superficies en encoder + última imagen pendiente + productor.
        config.queueDepth = 5
        config.showsCursor = true; config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await capture.startCapture()
        Diagnostics.shared.event("capture_started")
    }

    /// Benchmark del mismo encoder y control de flujo, sin capturar el escritorio.
    @MainActor func startSynthetic(width: Int, height: Int, fps: Int, bitrate: Int, lowLatency: Bool = true, realTime: Bool = true) throws {
        try configureEncoder(width: width, height: height, fps: fps, bitrate: bitrate, lowLatency: lowLatency, realTime: realTime)
    }
    func submitSynthetic(_ image: CVPixelBuffer, pts: CMTime) {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { self.offer(Frame(image: image, pts: pts, capturedAt: now)) }
    }
    @MainActor private func configureEncoder(width: Int, height: Int, fps: Int, bitrate: Int, lowLatency: Bool = true, realTime: Bool = true) throws {
        Diagnostics.shared.event("encoder_configure_started")
        guard encoder == nil else { throw DisplayError("El codificador ya está iniciado.") }
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        try requireSuccess(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { refcon, frameRefcon, status, flags, sample in
                guard let refcon else { return }
                let owner = Unmanaged<CapturePipeline>.fromOpaque(refcon).takeUnretainedValue()
                let sequence = frameRefcon.map { UInt32(truncatingIfNeeded: UInt(bitPattern: $0)) } ?? 0
                owner.queue.async {
                    guard !owner.stopped else { return }
                    guard status == noErr, !flags.contains(.frameDropped), let sample else {
                        Diagnostics.shared.event("encoder_output_failed", ["osstatus": .count(Int(status)), "dropped": .flag(flags.contains(.frameDropped))])
                        owner.fail("El codificador no produjo un fotograma (\(status))."); return
                    }
                    owner.encoded(sample, sequence: sequence)
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder), "Crear codificador H.264")
        guard let encoder else { throw DisplayError("No hay codificador H.264 disponible.") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: realTime,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2
        ]
        try requireSuccess(VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary), "Configurar codificador")
        try requireSuccess(VTCompressionSessionPrepareToEncodeFrames(encoder), "Preparar codificador")
        // RequireHardware impide fallback. La consulta UsingHardware es opcional
        // y no está soportada por el encoder de la primera prueba (-12900).
        statistics = RecentVideoMetrics(now: ProcessInfo.processInfo.systemUptime)
        Diagnostics.shared.event("encoder_ready", ["hardware_required": .flag(true)])
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped else { return }
        guard CGDisplayIsInMirrorSet(sourceDisplayID) == 0, CGDisplayIsOnline(sourceDisplayID) != 0 else {
            fail("La pantalla dejó de ser independiente."); return
        }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        offer(Frame(image: image, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), capturedAt: ProcessInfo.processInfo.systemUptime))
    }
    private func offer(_ frame: Frame) {
        guard !stopped else { return }
        let replaced = flow.offer(frame)
        statistics.captured(at: frame.capturedAt, replaced: replaced)
        pump()
    }
    private func pump() {
        guard !stopped, let encoder, let next = flow.takeNext() else { return }
        statistics.reserved(next.sequence, capturedAt: next.frame.capturedAt)
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: next.frame.image,
            presentationTimeStamp: next.frame.pts, duration: .invalid, frameProperties: nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(next.sequence)), infoFlagsOut: nil)
        if status != noErr {
            Diagnostics.shared.event("encoder_submit_failed", ["osstatus": .count(Int(status))])
            fail("Error de codificación: \(status)")
        }
    }
    private func encoded(_ sample: CMSampleBuffer, sequence: UInt32) {
        guard sequence == lastEncoded &+ 1 else { fail("El encoder cambió el orden de los fotogramas."); return }
        lastEncoded = sequence
        if sequence == 1 { Diagnostics.shared.event("first_frame_encoded") }
        do {
            let payload = try VideoPacket(sample: sample, sequence: sequence).serialized()
            statistics.sent(sequence, bytes: payload.count, at: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { [weak self] in self?.onFrame?(payload, sequence) }
        } catch {
            Diagnostics.shared.failure("video_serialization_failed", error: error)
            fail(error.localizedDescription)
        }
    }
    func acknowledge(_ sequence: UInt32) {
        queue.async {
            guard !self.stopped else { return }
            guard self.flow.acknowledge(sequence),
                  self.statistics.acknowledged(sequence, at: ProcessInfo.processInfo.systemUptime) else {
                self.fail("Confirmación de video inválida."); return
            }
            // Envía la última actualización aunque la captura ya esté inactiva.
            self.pump()
        }
    }
    func metrics(_ completion: @escaping @MainActor @Sendable (VideoMetrics) -> Void) {
        queue.async {
            let snapshot = self.statistics.snapshot(at: ProcessInfo.processInfo.systemUptime, waitingLatest: self.flow.latest != nil)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diagnostics.shared.failure("capture_stopped_with_error", error: error)
        fail("Captura detenida: \(error.localizedDescription)")
    }
    private func fail(_ message: String) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            Diagnostics.shared.event("capture_pipeline_failed")
            DispatchQueue.main.async { [weak self] in self?.onError?(message) }
        }
    }
    @MainActor func stop() async {
        Diagnostics.shared.event("capture_stop_requested")
        onFrame = nil; onError = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.stopped = true; self.flow.reset(); continuation.resume() }
        }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if let encoder = self.encoder {
                    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(encoder)
                }
                self.encoder = nil
                continuation.resume()
            }
        }
    }
    deinit { if let encoder { VTCompressionSessionInvalidate(encoder) } }
}
