import Foundation
import VideoToolbox
import CoreMedia

/// Decodifica H.264 con VideoToolbox fuera del hilo principal. Prefiere el
/// decodificador por hardware sin exigirlo: si la iMac no lo expone, VideoToolbox
/// usa software y el estado queda visible en las métricas.
final class VideoDecoder {
    private var session: VTDecompressionSession?
    private(set) var hardware: Bool?

    func prepare(format: CMVideoFormatDescription) throws {
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) { return }
        invalidate()
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        // IOSurface permite presentar la imagen sin copias adicionales.
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: VTDecompressionSession?
        try requireSuccess(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created), "Crear decodificador H.264")
        guard let created else { throw DisplayError("No hay decodificador H.264 disponible.") }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var usingHardware: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                           allocator: kCFAllocatorDefault, valueOut: &usingHardware)
        let value = usingHardware?.takeRetainedValue()
        hardware = status == noErr ? (value as? Bool) : nil
        session = created
        Diagnostics.shared.event("decoder_ready", ["hardware_known": .flag(hardware != nil), "hardware": .flag(hardware == true),
            "hardware_supported": .flag(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))])
    }

    /// `completion` se llama una sola vez, en main, con la imagen y los ms de decodificación.
    func decode(_ sample: CMSampleBuffer, completion: @escaping (Result<(CVImageBuffer, Double), Error>) -> Void) {
        guard let session else { completion(.failure(DisplayError("El decodificador no está preparado."))); return }
        let started = ProcessInfo.processInfo.systemUptime
        let once = Once()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            // Sin _1xRealTimePlayback: esa pista permite un modo de bajo consumo más lento.
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, flags, image, _, _ in
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            guard once.claim() else { return }
            DispatchQueue.main.async {
                if status == noErr, let image, !flags.contains(.frameDropped) {
                    completion(.success((image, elapsed)))
                } else {
                    Diagnostics.shared.event("decoder_frame_failed", ["osstatus": .count(Int(status)), "dropped": .flag(flags.contains(.frameDropped))])
                    completion(.failure(DisplayError("La iMac no pudo decodificar el video (\(status)).")))
                }
            }
        }
        if status != noErr, once.claim() {
            Diagnostics.shared.event("decoder_submit_failed", ["osstatus": .count(Int(status))])
            completion(.failure(DisplayError("La iMac no pudo decodificar el video (\(status)).")))
        }
    }
    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; hardware = nil
    }
    deinit { invalidate() }
}

/// Evita completar dos veces si VideoToolbox informa un error de forma síncrona y asíncrona.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Imágenes mostradas y tiempo de decodificación en una ventana de dos segundos.
struct DecodeStatistics {
    private var events: [(time: Double, decodeMS: Double?)] = []
    private var started: Double
    static let duration: Double = 2

    init(now: Double) { started = now }
    mutating func shown(at time: Double, decodeMS: Double?) {
        events.append((time, decodeMS))
        events.removeAll { $0.time <= time - Self.duration }
    }
    mutating func snapshot(at now: Double) -> (fps: Double, decodeMS: Double?) {
        events.removeAll { $0.time <= now - Self.duration }
        let elapsed = min(Self.duration, max(0.001, now - started))
        let times = events.compactMap(\.decodeMS)
        return (Double(events.count) / elapsed, times.isEmpty ? nil : times.reduce(0, +) / Double(times.count))
    }
}
