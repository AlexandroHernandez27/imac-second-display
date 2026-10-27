import Foundation

/// Cola de recepción acotada. Conserva el orden H.264 y espera al renderer sin
/// rechazar los otros fotogramas que ya estaban autorizados a estar en tránsito.
final class FrameReceiver {
    var render: ((VideoPacket, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onAcknowledged: ((UInt32) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var count = 0
    private var packets: [VideoPacket] = []
    private var rendering = false
    private var expectedSequence: UInt32 = 1
    private var generation = UUID()

    func receive(_ packet: VideoPacket) throws {
        guard packet.sequence == expectedSequence else { throw DisplayError("Secuencia de video incorrecta.") }
        guard packets.count < 3 else { throw DisplayError("El emisor excedió la cola de video permitida.") }
        expectedSequence &+= 1
        packets.append(packet); count = packets.count
        drain()
    }
    private func drain() {
        guard !rendering, let packet = packets.first, let render else { return }
        rendering = true
        let epoch = generation
        render(packet) { [weak self] result in
            guard let self, self.generation == epoch else { return }
            self.rendering = false
            switch result {
            case .success:
                self.packets.removeFirst(); self.count = self.packets.count
                self.onAcknowledged?(packet.sequence)
                self.drain()
            case .failure(let error):
                self.reset()
                self.onError?(error.localizedDescription)
            }
        }
    }
    func reset() {
        generation = UUID(); packets.removeAll(); count = 0
        rendering = false; expectedSequence = 1
    }
}
