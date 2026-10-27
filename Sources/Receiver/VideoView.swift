import AppKit
import AVFoundation

final class VideoView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var lastSPS = Data(), lastPPS = Data()
    var hasVideo = false
    private var generation = UUID()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    func display(_ packet: VideoPacket, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            if format == nil || packet.sps != lastSPS || packet.pps != lastPPS {
                format = try packet.formatDescription()
                lastSPS = packet.sps; lastPPS = packet.pps
            }
            guard videoLayer.status != .failed else { throw videoLayer.error ?? DisplayError("El receptor no pudo decodificar H.264.") }
            let sample = try packet.sampleBuffer(format: format!)
            enqueue(sample, generation: generation, deadline: Date(timeIntervalSinceNow: 2), completion: completion)
        } catch { completion(.failure(error)) }
    }
    private func enqueue(_ sample: CMSampleBuffer, generation: UUID, deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        guard self.generation == generation else { return }
        guard Date() < deadline, videoLayer.status != .failed else { completion(.failure(DisplayError("El receptor no está reproduciendo el video a tiempo."))); return }
        if videoLayer.isReadyForMoreMediaData {
            videoLayer.enqueue(sample); hasVideo = true
            completion(.success(()))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.enqueue(sample, generation: generation, deadline: deadline, completion: completion)
            }
        }
    }
    func reset() {
        generation = UUID()
        videoLayer.flushAndRemoveImage(); format = nil
        lastSPS = Data(); lastPPS = Data(); hasVideo = false
    }
}
