import Foundation
import ScreenCaptureKit
import VideoToolbox

// Flujo y encoder serializados en queue; configuración y callbacks de UI en main.
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Frame { let image: CVPixelBuffer; let capturedAt: Double; let refinement: Bool }
    /// ScreenCaptureKit no entrega imágenes mientras la pantalla está quieta, así
    /// que el último cuadro conservaría la calidad con que llegó. Al quedar quieta
    /// se reenvía esa imagen para que el encoder la afine; se detiene en cuanto el
    /// encoder ya no tiene nada que mejorar (salida diminuta) o tras el límite.
    static let refinementLimit = 8
    static let convergedBytes = 2048
    private let queue = DispatchQueue(label: "imac.capture", qos: .userInteractive)
    private var flow: FrameFlow<Frame>
    private var statistics = RecentVideoMetrics(now: ProcessInfo.processInfo.systemUptime)
    private var stopped = false
    private var lastEncoded: UInt32 = 0
    private var encoder: VTCompressionSession?
    private var stream: SCStream?
    private var sourceDisplayID: CGDirectDisplayID = 0
    private var frameInterval = 1.0 / 60
    private var lastImage: CVPixelBuffer?
    private var refinementsLeft = 0
    private var refinementTimer: DispatchSourceTimer?
    private var refinementSequences = Set<UInt32>()
    private var lastPTS: Int64 = 0
    private let refinementEnabled: Bool
    @MainActor var onFrame: ((Data, UInt32) -> Void)?
    @MainActor var onError: ((String) -> Void)?

    init(window: Int = 3, refinement: Bool = true) {
        flow = FrameFlow(capacity: window); refinementEnabled = refinement; super.init()
    }

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
        // Tres superficies en encoder, última imagen pendiente, imagen conservada
        // para refinar y una libre para el productor.
        config.queueDepth = 6
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
        queue.async { self.offer(Frame(image: image, capturedAt: now, refinement: false)) }
    }
    @MainActor private func configureEncoder(width: Int, height: Int, fps: Int, bitrate: Int, lowLatency: Bool = true, realTime: Bool = true) throws {
        Diagnostics.shared.event("encoder_configure_started")
        guard encoder == nil else { throw DisplayError("El codificador ya está iniciado.") }
        frameInterval = 1 / Double(max(1, fps))
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
        // High mejora el texto a igual bitrate. TCP no pierde datos: un IDR periódico
        // solo añadiría picos y bajadas de nitidez, así que queda como respaldo cada minuto.
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: realTime,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60
        ]
        try requireSuccess(VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary), "Configurar codificador")
        try requireSuccess(VTCompressionSessionPrepareToEncodeFrames(encoder), "Preparar codificador")
        // RequireHardware impide fallback. La consulta UsingHardware es opcional
        // y no está soportada por el encoder de la primera prueba (-12900).
        statistics = RecentVideoMetrics(now: ProcessInfo.processInfo.systemUptime)
        Diagnostics.shared.event("encoder_ready", ["hardware_required": .flag(true), "profile_high": .flag(true),
            "refinement": .flag(refinementEnabled)])
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
        offer(Frame(image: image, capturedAt: ProcessInfo.processInfo.systemUptime, refinement: false))
    }
    private func offer(_ frame: Frame) {
        guard !stopped else { return }
        let pendingWasRefinement = flow.latest?.refinement == true
        let replaced = flow.offer(frame)
        if frame.refinement {
            statistics.refined(at: frame.capturedAt)
        } else {
            statistics.captured(at: frame.capturedAt, replaced: replaced && !pendingWasRefinement)
            lastImage = frame.image
            refinementsLeft = refinementEnabled ? Self.refinementLimit : 0
            // Un refinamiento de la imagen anterior que converja después no debe
            // cancelar el de esta.
            refinementSequences.removeAll()
            // Tres intervalos sin cambios: la pantalla quedó quieta.
            scheduleRefinement(after: max(0.05, frameInterval * 3))
        }
        pump()
    }
    private func pump() {
        guard !stopped, let encoder, let next = flow.takeNext() else { return }
        statistics.reserved(next.sequence, capturedAt: next.frame.capturedAt)
        if next.frame.refinement { refinementSequences.insert(next.sequence) }
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: next.frame.image,
            presentationTimeStamp: nextPresentationTime(), duration: .invalid, frameProperties: nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(next.sequence)), infoFlagsOut: nil)
        if status != noErr {
            Diagnostics.shared.event("encoder_submit_failed", ["osstatus": .count(Int(status))])
            fail("Error de codificación: \(status)")
        }
    }
    /// Reloj monotónico propio: los refinamientos reutilizan una imagen ya enviada
    /// y el encoder exige marcas estrictamente crecientes. El receptor no las usa.
    private func nextPresentationTime() -> CMTime {
        let now = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        lastPTS = max(now, lastPTS + 1)
        return CMTime(value: lastPTS, timescale: 1_000_000_000)
    }
    private func scheduleRefinement(after seconds: Double) {
        refinementTimer?.cancel(); refinementTimer = nil
        guard refinementsLeft > 0, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.refine() }
        timer.resume()
        refinementTimer = timer
    }
    private func refine() {
        guard !stopped, refinementsLeft > 0, let image = lastImage else { return }
        // Solo con el flujo vacío: una imagen real nunca espera detrás de más de
        // un refinamiento, ni en la ventana ni en la cola del receptor.
        guard flow.latest == nil, flow.inFlight.isEmpty else {
            scheduleRefinement(after: frameInterval); return
        }
        refinementsLeft -= 1
        offer(Frame(image: image, capturedAt: ProcessInfo.processInfo.systemUptime, refinement: true))
        scheduleRefinement(after: frameInterval)
    }
    private func encoded(_ sample: CMSampleBuffer, sequence: UInt32) {
        guard sequence == lastEncoded &+ 1 else { fail("El encoder cambió el orden de los fotogramas."); return }
        lastEncoded = sequence
        if sequence == 1 { Diagnostics.shared.event("first_frame_encoded") }
        if refinementSequences.remove(sequence) != nil, CMSampleBufferGetTotalSampleSize(sample) < Self.convergedBytes {
            refinementsLeft = 0 // Convergió: más copias solo gastarían ancho de banda.
        }
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
            self.cancelRefinement()
            Diagnostics.shared.event("capture_pipeline_failed")
            DispatchQueue.main.async { [weak self] in self?.onError?(message) }
        }
    }
    private func cancelRefinement() {
        refinementTimer?.cancel(); refinementTimer = nil
        refinementsLeft = 0; lastImage = nil; refinementSequences.removeAll()
    }
    @MainActor func stop() async {
        Diagnostics.shared.event("capture_stop_requested")
        onFrame = nil; onError = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.stopped = true; self.cancelRefinement(); self.flow.reset(); continuation.resume() }
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
    deinit { refinementTimer?.cancel(); if let encoder { VTCompressionSessionInvalidate(encoder) } }
}
