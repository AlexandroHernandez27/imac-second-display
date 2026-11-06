import AppKit
import AVFoundation

/// Presenta el video. Camino principal: VideoToolbox decodifica y la imagen ya
/// decodificada se muestra de inmediato; recién entonces se confirma al emisor,
/// de modo que su ventana de tres fotogramas acota la latencia hasta el panel.
/// Si VideoToolbox no puede crear la sesión, se usa el camino anterior: H.264
/// comprimido hacia AVSampleBufferDisplayLayer, que confirma al encolar.
final class VideoView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let decoder = VideoDecoder()
    private var format: CMVideoFormatDescription?
    private var imageFormat: CMVideoFormatDescription?
    private var lastSPS = Data(), lastPPS = Data()
    private(set) var compressedFallback = false
    var hardwareDecoding: Bool? { compressedFallback ? nil : decoder.hardware }
    var hasVideo = false
    /// Se llama en main por cada imagen mostrada, con los ms de decodificación si se conocen.
    var onShown: ((Double?) -> Void)?
    private var generation = UUID()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
    func display(_ packet: VideoPacket, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            if format == nil || packet.sps != lastSPS || packet.pps != lastPPS {
                let created = try packet.formatDescription()
                format = created
                lastSPS = packet.sps; lastPPS = packet.pps
                let dimensions = CMVideoFormatDescriptionGetDimensions(created)
                Diagnostics.shared.event("video_format_ready", ["width": .count(Int(dimensions.width)), "height": .count(Int(dimensions.height))])
                if !compressedFallback {
                    do { try decoder.prepare(format: created) }
                    catch {
                        compressedFallback = true
                        Diagnostics.shared.failure("decoder_fallback", error: error)
                    }
                }
            }
            guard videoLayer.status != .failed else { throw videoLayer.error ?? DisplayError("El receptor no pudo mostrar el video.") }
            let sample = try packet.sampleBuffer(format: format!)
            let epoch = generation
            if compressedFallback {
                enqueueCompressed(sample, generation: epoch, deadline: Date(timeIntervalSinceNow: 2), completion: completion)
                return
            }
            decoder.decode(sample) { [weak self] result in
                guard let self, self.generation == epoch else { return }
                switch result {
                case .success(let (image, milliseconds)):
                    do {
                        try self.show(image)
                        self.onShown?(milliseconds)
                        completion(.success(()))
                    } catch { completion(.failure(error)) }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch { completion(.failure(error)) }
    }
    private func show(_ image: CVImageBuffer) throws {
        if imageFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(imageFormat!, imageBuffer: image) {
            var created: CMVideoFormatDescription?
            try requireSuccess(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                formatDescriptionOut: &created), "Preparar imagen")
            imageFormat = created
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try requireSuccess(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: imageFormat!, sampleTiming: &timing, sampleBufferOut: &sample), "Preparar imagen")
        guard let sample else { throw DisplayError("No se pudo preparar la imagen.") }
        markDisplayImmediately(sample)
        guard videoLayer.status != .failed else { throw videoLayer.error ?? DisplayError("El receptor no pudo mostrar el video.") }
        // Ya está decodificada: si la capa aún tiene otra pendiente, se reemplaza
        // en lugar de acumular retraso.
        if !videoLayer.isReadyForMoreMediaData { videoLayer.flush() }
        videoLayer.enqueue(sample)
        hasVideo = true
    }
    private func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    private func enqueueCompressed(_ sample: CMSampleBuffer, generation: UUID, deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        guard self.generation == generation else { return }
        guard videoLayer.status != .failed else {
            completion(.failure(videoLayer.error ?? DisplayError("El receptor no pudo decodificar H.264."))); return
        }
        guard Date() < deadline else {
            Diagnostics.shared.event("renderer_timeout")
            completion(.failure(DisplayError("El receptor no está reproduciendo el video a tiempo."))); return
        }
        if videoLayer.isReadyForMoreMediaData {
            videoLayer.enqueue(sample); hasVideo = true
            onShown?(nil)
            completion(.success(()))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                self?.enqueueCompressed(sample, generation: generation, deadline: deadline, completion: completion)
            }
        }
    }
    func reset() {
        generation = UUID()
        decoder.invalidate()
        videoLayer.flushAndRemoveImage(); format = nil; imageFormat = nil
        lastSPS = Data(); lastPPS = Data(); hasVideo = false; compressedFallback = false
    }
}
