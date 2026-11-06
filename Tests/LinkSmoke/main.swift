import AppKit
import Network
import VideoToolbox

// Prueba de enlace en una sola Mac: anuncio Bonjour limitado a la interfaz
// elegida, descubrimiento, TLS-PSK por el endpoint Bonjour, por IPv6 link-local
// y por IPv4, saludo v3, H.264 real, decoder de producción, ACK tras decodificar
// y reporte del receptor. Ambos extremos están en esta Mac: el tráfico no cruza
// el cable ni mide la iMac. Usa el puerto 47777 para no chocar con la app.

let testPort: UInt16 = 47_777

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DisplayError(message) }
}
func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    return condition()
}

/// Tres muestras del encoder de producción.
@MainActor func encodedPayloads() throws -> [Data] {
    let pipeline = CapturePipeline(window: 3, refinement: false)
    var payloads = [Data](), failure: String?
    pipeline.onFrame = { data, sequence in payloads.append(data); pipeline.acknowledge(sequence) }
    pipeline.onError = { failure = $0 }
    try pipeline.startSynthetic(width: 1280, height: 720, fps: 60, bitrate: 8_000_000)
    var pool: CVPixelBufferPool?
    try requireSuccess(CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool), "Crear pool")
    for shade: Int32 in [40, 120, 200] {
        var image: CVPixelBuffer?
        try requireSuccess(CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &image), "Crear imagen")
        CVPixelBufferLockBaseAddress(image!, [])
        memset(CVPixelBufferGetBaseAddress(image!), shade, CVPixelBufferGetBytesPerRow(image!) * 720)
        CVPixelBufferUnlockBaseAddress(image!, [])
        let before = payloads.count
        pipeline.submitSynthetic(image!, pts: .invalid)
        try check(waitFor(3) { payloads.count > before || failure != nil } && failure == nil, failure ?? "El encoder no produjo video")
    }
    var stopped = false
    Task { @MainActor in await pipeline.stop(); stopped = true }
    _ = waitFor(5) { stopped }
    return payloads
}

/// Lado emisor: acepta el saludo, envía el video y registra ACKs y reporte.
@MainActor final class TestSender {
    var helloVersion = 0, acknowledged = 0
    var report: ReceiverReport?
    var failure: String?
    private var listeners = [NWListener]()
    private var channels = [PacketChannel]()
    private(set) var ready = 0

    init(secret: String, hosts: [String], payloads: [Data]) throws {
        for host in hosts {
            let parameters = try Pairing.parameters(code: secret)
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: testPort)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .ready = state { self?.ready += 1 }
                    if case .failed(let error) = state { self?.failure = "Listener: \(error)" }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection, payloads: payloads) }
            }
            listener.start(queue: .main)
            listeners.append(listener)
        }
    }
    private func accept(_ connection: NWConnection, payloads: [Data]) {
        let channel = PacketChannel(connection)
        channels.append(channel)
        channel.onPacket = { [weak self] data in
            guard let self else { return }
            if let peer = Wire.peer(forHello: data) {
                self.helloVersion = peer.version
                channel.send(Wire.accepted)
                for payload in payloads { channel.send(payload) }
            } else if data.first == 4, data.count == 5 {
                self.acknowledged += 1
            } else if let report = ReceiverReport(data: data) {
                self.report = report
            } else { self.failure = "Mensaje inesperado del receptor" }
        }
        channel.start()
    }
    func reset() {
        helloVersion = 0; acknowledged = 0; report = nil
        channels.forEach { $0.onClose = nil; $0.close() }; channels = []
    }
    func stop() { reset(); listeners.forEach { $0.cancel() }; listeners = [] }
}

/// Lado receptor, como Receiver: saludo v3, decoder de producción, ACK al decodificar.
@MainActor func receive(over connection: NWConnection, sender: TestSender, frames: Int) throws {
    let decoder = VideoDecoder()
    defer { decoder.invalidate() }
    var format: CMVideoFormatDescription?
    var decoded = 0, failure: String?
    let channel = PacketChannel(connection)
    defer { channel.onClose = nil; channel.close() }
    channel.onReady = { channel.send(Wire.hello) }
    channel.onPacket = { data in
        if data == Wire.accepted { return }
        do {
            let packet = try VideoPacket(data: data)
            if format == nil { format = try packet.formatDescription(); try decoder.prepare(format: format!) }
            decoder.decode(try packet.sampleBuffer(format: format!)) { result in
                switch result {
                case .success:
                    decoded += 1
                    channel.send(Wire.ack(packet.sequence))
                    if decoded == frames {
                        channel.send(ReceiverReport(shownFPS: 59.9, decodeMS: 4.2, hardware: decoder.hardware,
                                                    compressedFallback: false).serialized())
                    }
                case .failure(let error): failure = error.localizedDescription
                }
            }
        } catch { failure = error.localizedDescription }
    }
    channel.onClose = { reason in if decoded < frames { failure = reason } }
    channel.start()
    try check(waitFor(10) { sender.report != nil || failure != nil || sender.failure != nil } && failure == nil && sender.failure == nil,
              failure ?? sender.failure ?? "No llegó el reporte del receptor")
    try check(sender.helloVersion == 3 && sender.acknowledged == frames && decoded == frames && sender.report?.decodeMS == 4.2,
              "Saludo, ACKs o reporte incorrectos")
}

@MainActor func run() throws {
    let diagnostics = URL(fileURLWithPath: ".build/link-diagnostics-\(UUID().uuidString)", isDirectory: true)
    Diagnostics.shared.configure(role: "LinkTest", directory: diagnostics)
    defer { try? FileManager.default.removeItem(at: diagnostics) }

    let sample = ReceiverReport(shownFPS: 59.94, decodeMS: 12.34, hardware: false, compressedFallback: false)
    try check(ReceiverReport(data: sample.serialized()) == ReceiverReport(shownFPS: 59.9, decodeMS: 12.3, hardware: false, compressedFallback: false),
              "El reporte del receptor no conserva sus campos")
    try check(ReceiverReport(data: Data([7, 0xF0, 0, 0, 0, 0])) == nil && ReceiverReport(data: Data([7, 0])) == nil, "Aceptó un reporte inválido")
    try check(Wire.peer(forHello: Wire.hello) == Wire.Peer(window: 3, version: 3)
              && Wire.peer(forHello: Wire.helloV2) == Wire.Peer(window: 3, version: 2)
              && Wire.peer(forHello: Wire.helloV1) == Wire.Peer(window: 1, version: 1)
              && Wire.peer(forHello: Data([1, 73, 83, 68, 9])) == nil, "Negociación de versiones incorrecta")
    try check(LinkInventory.deviceSpeed("High Speed (480 Mbps)") == 480 && LinkInventory.deviceSpeed("Super Speed Plus (10 Gbps)") == 10000
              && LinkInventory.deviceSpeed("Unknown") == nil && LinkInventory.hostSpeed(3) == 480 && LinkInventory.hostSpeed(4) == 5000,
              "Lectura de velocidad USB incorrecta")
    print("PASS: reporte del receptor, saludos v1/v2/v3 y velocidades USB.")

    let links = LinkInventory.current()
    for link in links {
        print("Enlace: \(link.kind.title) · IPv4 \(link.ipv4 != nil ? "sí" : "no") · IPv6 link-local \(link.ipv6LinkLocal != nil ? "sí" : "no") · \(link.speedLabel ?? "-")")
    }
    let requireUSB = CommandLine.arguments.contains("--require-usb")
    guard let link = links.first(where: { $0.kind == .usbCable }) ?? (requireUSB ? nil : links.first) else {
        throw DisplayError(requireUSB ? "No hay cable USB activo hacia la iMac." : "No hay enlaces locales para probar.")
    }
    print("Probando sobre: \(link.kind.title)")
    let payloads = try encodedPayloads()
    try check(payloads.count == 3, "Faltan muestras codificadas")

    let secret = try Pairing.generate()
    let sender = try TestSender(secret: secret, hosts: link.bindHosts, payloads: payloads)
    defer { sender.stop() }
    try check(waitFor(5) { sender.ready == link.bindHosts.count || sender.failure != nil } && sender.failure == nil,
              sender.failure ?? "Listeners sin iniciar")

    let advertiser = BonjourAdvertiser()
    var registration: DNSServiceErrorType?
    advertiser.onUpdate = { registration = $0 }
    try check(advertiser.start(interfaceIndex: link.interfaceIndex, link: link.kind, port: testPort) == 0, "No se pudo anunciar el servicio")
    defer { advertiser.stop() }
    let browser = SenderBrowser()
    browser.start()
    defer { browser.stop() }
    try check(waitFor(8) { browser.found.contains { $0.interface?.name == link.name } }, "La MacBook no apareció por Bonjour en el enlace")
    try check(registration == 0, "Registro Bonjour con error")
    try check(!browser.found.contains { $0.interface?.name != link.name && $0.interface?.type != .loopback },
              "El servicio se anunció también en otras interfaces")
    let found = browser.found.first { $0.interface?.name == link.name }!
    try check(found.link == link.kind, "El registro TXT no indica el tipo de enlace")
    print("PASS: Bonjour solo en la interfaz del enlace, con tipo «\(found.link.title)».")

    // 1) Como el receptor: endpoint Bonjour y la interfaz donde se encontró.
    let parameters = try Pairing.parameters(code: secret)
    if let interface = found.interface { parameters.requiredInterface = interface }
    try receive(over: NWConnection(to: found.endpoint, using: parameters), sender: sender, frames: payloads.count)
    print("PASS: conexión por Bonjour → TLS-PSK → saludo v3 → 3 cuadros decodificados → ACKs → reporte.")
    // 2) Cada dirección del enlace, como la IP manual.
    for host in link.bindHosts {
        sender.reset()
        try receive(over: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: testPort)!,
                                       using: try Pairing.parameters(code: secret)), sender: sender, frames: payloads.count)
        print("PASS: conexión directa por \(host.contains(":") ? "IPv6 link-local" : "IPv4") con el mismo protocolo.")
    }
    let log = String(decoding: try Diagnostics.shared.report(), as: UTF8.self)
    try check(!log.contains(link.name) && !link.bindHosts.contains(where: log.contains), "El registro contiene la interfaz o una dirección")
    print("PASS: prueba de enlace completa. Ambos extremos en esta Mac; la prueba física con la iMac sigue pendiente.")
}

MainActor.assumeIsolated {
    do { try run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
}
