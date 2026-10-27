import Foundation

/// Conserva una sola imagen cruda reciente y acota los fotogramas ya codificados.
/// Nunca descarta un fotograma H.264: los siguientes pueden depender de él.
struct FrameFlow<Frame> {
    let capacity: Int
    private(set) var inFlight: [UInt32] = []
    private(set) var latest: Frame?
    private var nextSequence: UInt32 = 1

    init(capacity: Int) { precondition((1...3).contains(capacity)); self.capacity = capacity }
    @discardableResult mutating func offer(_ frame: Frame) -> Bool {
        let replaced = latest != nil
        latest = frame
        return replaced
    }
    mutating func takeNext() -> (sequence: UInt32, frame: Frame)? {
        guard inFlight.count < capacity, let frame = latest else { return nil }
        latest = nil
        let sequence = nextSequence
        nextSequence &+= 1
        inFlight.append(sequence)
        return (sequence, frame)
    }
    mutating func acknowledge(_ sequence: UInt32) -> Bool {
        guard inFlight.first == sequence else { return false }
        inFlight.removeFirst()
        return true
    }
    mutating func reset() { latest = nil; inFlight.removeAll(); nextSequence = 1 }
}

struct VideoMetrics {
    let capturedFPS: Double
    let deliveredFPS: Double
    let megabitsPerSecond: Double
    let preparationMS: Double?
    let ackMS: Double?
    let inFlight: Int
    let waitingLatest: Bool
    let sourceIdle: Bool
    let oldestPendingAge: Double
    let replacedFrames: Int
}

/// Ventana temporal, no promedio acumulado desde la conexión. Reloj monotónico.
struct RecentVideoMetrics {
    private struct Event {
        let time: Double
        var captured = 0, delivered = 0, bytes = 0, replaced = 0
        var preparation: Double?, ack: Double?
    }
    private struct Pending { let captured: Double; var sent: Double? }
    private var events: [Event] = []
    private var pending: [UInt32: Pending] = [:]
    private var started: Double
    private var lastCapture: Double?
    static let duration: Double = 2

    init(now: Double) { started = now }
    mutating func captured(at now: Double, replaced: Bool) {
        lastCapture = now
        append(Event(time: now, captured: 1, replaced: replaced ? 1 : 0))
    }
    mutating func reserved(_ sequence: UInt32, capturedAt: Double) {
        pending[sequence] = Pending(captured: capturedAt)
    }
    mutating func sent(_ sequence: UInt32, bytes: Int, at now: Double) {
        guard var frame = pending[sequence] else { return }
        frame.sent = now; pending[sequence] = frame
        append(Event(time: now, bytes: bytes, preparation: max(0, now - frame.captured) * 1000))
    }
    mutating func acknowledged(_ sequence: UInt32, at now: Double) -> Bool {
        guard let frame = pending[sequence], let sent = frame.sent else { return false }
        pending.removeValue(forKey: sequence)
        append(Event(time: now, delivered: 1, ack: max(0, now - sent) * 1000))
        return true
    }
    private mutating func append(_ event: Event) {
        events.append(event)
        events.removeAll { $0.time <= event.time - Self.duration }
    }
    mutating func snapshot(at now: Double, waitingLatest: Bool) -> VideoMetrics {
        events.removeAll { $0.time <= now - Self.duration }
        let elapsed = min(Self.duration, max(0.001, now - started))
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return VideoMetrics(
            capturedFPS: Double(events.reduce(0) { $0 + $1.captured }) / elapsed,
            deliveredFPS: Double(events.reduce(0) { $0 + $1.delivered }) / elapsed,
            megabitsPerSecond: Double(events.reduce(0) { $0 + $1.bytes }) * 8 / elapsed / 1_000_000,
            preparationMS: mean(events.compactMap(\.preparation)), ackMS: mean(events.compactMap(\.ack)),
            inFlight: pending.count, waitingLatest: waitingLatest,
            sourceIdle: now - (lastCapture ?? started) > 0.5 && pending.isEmpty && !waitingLatest,
            oldestPendingAge: pending.values.map { max(0, now - $0.captured) }.max() ?? 0,
            replacedFrames: events.reduce(0) { $0 + $1.replaced })
    }
}
