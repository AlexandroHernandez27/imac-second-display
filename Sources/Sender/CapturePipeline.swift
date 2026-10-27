import Foundation
import ScreenCaptureKit
import VideoToolbox

// Configuración y callbacks de UI en main; encoder en queue después de iniciar;
// busy/stopped/pendingSequence bajo lock. stop drena queue antes de liberar encoder.
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "imac.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var stopped = false
    private var nextSequence: UInt32 = 1
    private var pendingSequence: UInt32?
    private var encoder: VTCompressionSession?
    private var stream: SCStream?
    private var sourceDisplayID: CGDirectDisplayID = 0
    private(set) var hardwareEncoder = false
    var onFrame: ((Data, UInt32) -> Void)?
    var onError: ((String) -> Void)?

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, bitrate: Int) async throws {
        sourceDisplayID = displayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              CGDisplayIsInMirrorSet(displayID) == 0 else { throw DisplayError("No se encontró la pantalla virtual independiente para capturar.") }
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        try requireSuccess(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: { refcon, _, status, flags, sample in
                guard let refcon else { return }
                let owner = Unmanaged<CapturePipeline>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, !flags.contains(.frameDropped), let sample else {
                    owner.fail("El codificador no pudo producir un fotograma (\(status))."); return
                }
                owner.encoded(sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder), "Crear codificador H.264")
        guard let encoder else { throw DisplayError("No hay codificador H.264 disponible.") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2
        ]
        try requireSuccess(VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary), "Configurar codificador")
        try requireSuccess(VTCompressionSessionPrepareToEncodeFrames(encoder), "Preparar codificador")
        // La especificación RequireHardware... ya impide fallback a software.
        // Algunos encoders no exponen la propiedad de consulta UsingHardware...
        // (observado -12900); esa telemetría opcional no debe bloquear la captura.
        hardwareEncoder = true
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        stream = capture
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await capture.startCapture()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CGDisplayIsInMirrorSet(sourceDisplayID) == 0, CGDisplayIsOnline(sourceDisplayID) != 0 else {
            fail("La pantalla dejó de ser independiente."); return
        }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer), let encoder else { return }
        lock.lock()
        guard !busy, !stopped else { lock.unlock(); return }
        busy = true; pendingSequence = nextSequence
        nextSequence &+= 1
        lock.unlock()
        let statusCode = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), duration: .invalid,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if statusCode != noErr { fail("Error de codificación: \(statusCode)") }
    }
    private func encoded(_ sample: CMSampleBuffer) {
        lock.lock(); let sequence = pendingSequence; let isStopped = stopped; lock.unlock()
        guard !isStopped, let sequence else { return }
        do {
            let payload = try VideoPacket(sample: sample, sequence: sequence).serialized()
            DispatchQueue.main.async { [weak self] in self?.onFrame?(payload, sequence) }
        } catch { fail(error.localizedDescription) }
    }
    func acknowledge(_ sequence: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingSequence == sequence else { return false }
        pendingSequence = nil; busy = false
        return true
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("Captura detenida: \(error.localizedDescription)") }
    private func fail(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onError?(message) } }
    @MainActor func stop() async {
        lock.withLock { stopped = true }
        onFrame = nil; onError = nil
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
