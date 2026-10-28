import AppKit
import VideoToolbox
import Network

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DisplayError(message) }
}
func rejects(_ block: () throws -> Void) -> Bool { do { try block(); return false } catch { return true } }
func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    return condition()
}
final class SampleResult {
    let lock = NSLock()
    var sample: CMSampleBuffer?, pixel: CVPixelBuffer?
    var error: OSStatus = 0
}

func testCodec() throws -> Data {
    let result = SampleResult()
    var encoder: VTCompressionSession?
    try requireSuccess(VTCompressionSessionCreate(allocator: nil, width: 640, height: 480, codecType: kCMVideoCodecType_H264,
        encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: { context, _, status, _, sample in
            let state = Unmanaged<SampleResult>.fromOpaque(context!).takeUnretainedValue()
            state.lock.withLock { state.sample = sample; state.error = status }
        }, refcon: Unmanaged.passUnretained(result).toOpaque(), compressionSessionOut: &encoder), "Crear encoder de prueba")
    guard let encoder else { throw DisplayError("Encoder ausente") }
    defer { VTCompressionSessionInvalidate(encoder) }
    try requireSuccess(VTSessionSetProperties(encoder, propertyDictionary: [kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
        kVTCompressionPropertyKey_AverageBitRate: 12_000_000,
        kVTCompressionPropertyKey_ExpectedFrameRate: 30,
        kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2] as CFDictionary), "Configurar encoder")
    try requireSuccess(VTCompressionSessionPrepareToEncodeFrames(encoder), "Preparar encoder")
    var image: CVPixelBuffer?
    try requireSuccess(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), "Crear patrón")
    guard let image else { throw DisplayError("Patrón ausente") }
    CVPixelBufferLockBaseAddress(image, [])
    let stride = CVPixelBufferGetBytesPerRow(image)
    let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<480 { for x in 0..<640 {
        let offset = y * stride + x * 4
        pixels[offset] = 40; pixels[offset + 1] = 120; pixels[offset + 2] = 200; pixels[offset + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(image, [])
    try requireSuccess(VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), "Codificar patrón")
    try check(waitFor(3) { result.lock.withLock { result.sample != nil || result.error != 0 } }, "El encoder no entregó el primer fotograma sin flush")
    guard let sample = result.lock.withLock({ result.sample }) else { throw DisplayError("Sin fotograma codificado") }
    let payload = try VideoPacket(sample: sample, sequence: 1).serialized()
    let packet = try VideoPacket(data: payload)
    let format = try packet.formatDescription()
    let decodedSample = try packet.sampleBuffer(format: format)
    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
        let state = Unmanaged<SampleResult>.fromOpaque(context!).takeUnretainedValue()
        state.lock.withLock { state.pixel = image; state.error = status }
    }, decompressionOutputRefCon: Unmanaged.passUnretained(result).toOpaque())
    var decoder: VTDecompressionSession?
    try requireSuccess(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
        outputCallback: &callback, decompressionSessionOut: &decoder), "Crear decoder")
    guard let decoder else { throw DisplayError("Decoder ausente") }
    defer { VTDecompressionSessionInvalidate(decoder) }
    try requireSuccess(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: decodedSample,
        flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil), "Decodificar patrón")
    VTDecompressionSessionWaitForAsynchronousFrames(decoder)
    guard let decoded = result.lock.withLock({ result.pixel }) else { throw DisplayError("Sin imagen decodificada") }
    try check(CVPixelBufferGetWidth(decoded) == 640 && CVPixelBufferGetHeight(decoded) == 480, "Dimensiones incorrectas")
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    let output = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
    let offset = 240 * CVPixelBufferGetBytesPerRow(decoded) + 320 * 4
    let correctColor = abs(Int(output[offset]) - 40) < 15 && abs(Int(output[offset + 1]) - 120) < 15 && abs(Int(output[offset + 2]) - 200) < 15
    CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
    try check(correctColor, "El patrón cambió de color al decodificar")
    try check(rejects { _ = try VideoPacket(data: Data(payload.dropLast())) }, "Aceptó video truncado")
    var badLength = payload; badLength.replaceSubrange(5..<9, with: [255, 255, 255, 255])
    try check(rejects { _ = try VideoPacket(data: badLength) }, "Aceptó tamaño de parámetros inválido")
    print("PASS: H.264 por hardware → paquete → decodificación; dimensiones, color y límites.")
    return payload
}

func testNetwork(payload: Data, wrongKey: Bool) throws {
    let payloads: [Data] = (1...3).map { sequence in
        var data = payload, bytes = Data(); bytes.put32(UInt32(sequence))
        data.replaceSubrange(1..<5, with: bytes)
        return data
    }
    let serverCode = try Pairing.generate()
    let params = try Pairing.parameters(code: serverCode)
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: params)
    var ready = false, received = 0, acknowledged = 0, closed = false
    var server: PacketChannel?, client: PacketChannel?
    var failure: String?
    listener.stateUpdateHandler = { state in
        if case .ready = state { ready = true }
        if case .failed(let error) = state { failure = error.localizedDescription }
    }
    listener.newConnectionHandler = { connection in
        let peer = PacketChannel(connection); server = peer
        peer.onPacket = { data in
            if data == Wire.hello {
                peer.send(Wire.accepted)
                for payload in payloads { peer.send(payload) }
            }
            else if acknowledged < 3, data == Wire.ack(UInt32(acknowledged + 1)) { acknowledged += 1 }
            else { failure = "Mensaje inesperado en prueba" }
        }
        peer.onClose = { _ in closed = true }
        peer.start()
    }
    listener.start(queue: .main)
    defer {
        client?.onClose = nil; server?.onClose = nil
        client?.close(); server?.close(); listener.cancel()
    }
    try check(waitFor(5) { ready || failure != nil } && ready, failure ?? "Listener no inició")
    let clientCode = wrongKey ? try Pairing.generate() : serverCode
    let peer = PacketChannel(NWConnection(host: "127.0.0.1", port: listener.port!, using: try Pairing.parameters(code: clientCode)))
    client = peer
    peer.onReady = { peer.send(Wire.hello) }
    peer.onPacket = { data in
        if data == Wire.accepted { return }
        if received < 3, data == payloads[received] { received += 1; peer.send(Wire.ack(UInt32(received))) }
        else { failure = "El video recibido cambió" }
    }
    peer.onClose = { _ in closed = true }
    peer.start()
    if wrongKey {
        try check(waitFor(15) { closed || received > 0 } && closed && received == 0, "Se aceptó una clave incorrecta")
        print("PASS: clave incorrecta rechazada sin entregar video.")
    } else {
        try check(waitFor(10) { acknowledged == 3 || failure != nil || closed } && received == 3 && acknowledged == 3, failure ?? "Falló TLS/entrega/ACK")
        print("PASS: TLS-PSK local → tres muestras H.264 íntegras en tránsito → ACKs en orden.")
        var remoteClosed = false
        peer.onClose = { _ in remoteClosed = true }
        server?.onClose = nil; server?.close()
        try check(waitFor(5) { remoteClosed }, "El receptor no detectó el cierre remoto")
        print("PASS: cierre remoto detectado y registrado sin ocultar errores de red.")
    }
}

func testFlowAndMetrics() throws {
    var flow = FrameFlow<Int>(capacity: 3)
    for value in 1...3 {
        flow.offer(value)
        let next = flow.takeNext()
        try check(next?.sequence == UInt32(value) && next?.frame == value, "Reserva fuera de orden")
    }
    flow.offer(4)
    try check(flow.offer(5), "No reemplazó la imagen cruda obsoleta")
    try check(flow.takeNext() == nil && flow.inFlight.count == 3, "La ventana excedió tres fotogramas")
    try check(!flow.acknowledge(2) && flow.inFlight.count == 3, "Aceptó un ACK fuera de orden")
    try check(flow.acknowledge(1), "Rechazó el primer ACK")
    let final = flow.takeNext() // Sin nuevos callbacks de captura: conserva el último cambio.
    try check(final?.frame == 5 && final?.sequence == 4, "Se perdió el último cambio al quedar inactiva la captura")
    try check(!flow.acknowledge(1), "Aceptó un ACK duplicado")
    flow.reset()
    try check(flow.inFlight.isEmpty && flow.latest == nil, "La reconexión conserva estado anterior")
    var legacy = FrameFlow<Int>(capacity: 1)
    legacy.offer(1); _ = legacy.takeNext(); legacy.offer(2)
    try check(legacy.takeNext() == nil, "Rompió la ventana del receptor antiguo")
    try check(legacy.acknowledge(1) && legacy.takeNext()?.frame == 2, "Perdió la última imagen en modo antiguo")

    var metrics = RecentVideoMetrics(now: 0)
    // Un minuto inactivo seguido de dos segundos de movimiento a 60 FPS.
    for index in 0..<120 {
        let time = 60 + Double(index) / 60
        let sequence = UInt32(index + 1)
        metrics.captured(at: time, replaced: false)
        metrics.reserved(sequence, capturedAt: time)
        metrics.sent(sequence, bytes: 1000, at: time + 0.001)
        try check(metrics.acknowledged(sequence, at: time + 0.008), "ACK no registrado")
    }
    let moving = metrics.snapshot(at: 62, waitingLatest: false)
    try check(moving.deliveredFPS > 59 && moving.capturedFPS > 59, "Los FPS siguen promediando el minuto inactivo")
    try check(abs((moving.ackMS ?? 0) - 7) < 0.01, "El ACK no usa el reloj de la sesión")
    let idle = metrics.snapshot(at: 65, waitingLatest: false)
    try check(idle.deliveredFPS == 0 && idle.megabitsPerSecond == 0 && idle.ackMS == nil && idle.sourceIdle,
        "Las métricas no caducan al quedar inactiva la pantalla")
    print("PASS: ventana acotada, última actualización tras idle, ACKs y métricas recientes.")
}

func testReceiverQueue(payload: Data) throws {
    func packet(_ sequence: UInt32) throws -> VideoPacket {
        var data = payload, bytes = Data(); bytes.put32(sequence)
        data.replaceSubrange(1..<5, with: bytes)
        return try VideoPacket(data: data)
    }
    let receiver = FrameReceiver()
    var completions = [(Result<Void, Error>) -> Void]()
    var acks = [UInt32]()
    receiver.render = { _, completion in completions.append(completion) }
    receiver.onAcknowledged = { acks.append($0) }
    for sequence in 1...3 { try receiver.receive(packet(UInt32(sequence))) }
    try check(receiver.count == 3 && completions.count == 1, "El renderer no serializa su cola")
    try check(rejects { try receiver.receive(packet(4)) }, "Aceptó más de tres fotogramas")
    completions[0](.success(()))
    try check(acks == [1] && receiver.count == 2 && completions.count == 2, "No liberó el siguiente fotograma")
    completions[1](.success(())); completions[2](.success(()))
    try check(acks == [1, 2, 3] && receiver.count == 0, "ACK fuera de orden")
    try receiver.receive(packet(4))
    let stale = completions[3]
    receiver.reset()
    try receiver.receive(packet(1))
    stale(.success(()))
    try check(receiver.count == 1 && acks == [1, 2, 3], "Una respuesta vieja contaminó la reconexión")
    completions[4](.success(()))
    try check(receiver.count == 0 && acks == [1, 2, 3, 1], "La nueva sesión no pudo continuar")
    print("PASS: receptor lento, cola máxima, orden y callbacks obsoletos tras reconectar.")
}

do {
    let diagnostics = URL(fileURLWithPath: ".build/protocol-diagnostics-\(UUID().uuidString)", isDirectory: true)
    Diagnostics.shared.configure(role: "ProtocolTest", directory: diagnostics)
    defer { try? FileManager.default.removeItem(at: diagnostics) }
    try check(Wire.frameWindow(forHello: Wire.hello) == 3 && Wire.frameWindow(forHello: Wire.helloV1) == 1,
        "El emisor no acepta los protocolos soportados")
    try check(Wire.frameWindow(forHello: Data([1, 73, 83, 68, 99])) == nil && Wire.frameWindow(forHello: Data()) == nil,
        "Se aceptó un protocolo desconocido")
    try check(isLocalIPv4("192.168.1.2") && isLocalIPv4("10.0.0.2") && !isLocalIPv4("8.8.8.8") && !isLocalIPv4("192.168.1.999"), "Filtro LAN inválido")
    try check(rejects { _ = try Pairing.parameters(code: "123456") }, "Aceptó una clave débil")
    let payload = try testCodec()
    try testFlowAndMetrics()
    try testReceiverQueue(payload: payload)
    try testNetwork(payload: payload, wrongKey: false)
    try testNetwork(payload: payload, wrongKey: true)
    let log = String(decoding: try Diagnostics.shared.report(), as: UTF8.self)
    try check(log.contains("tls_ready") && log.contains("transport_close") && log.contains("transport_header_incomplete"),
        "Faltan etapas de conexión y cierre en el registro")
    try check(log.contains("\"domain\":\"tls\"") && !log.contains("127.0.0.1"), "Falta error TLS o se registró una dirección")
    print("PASS: pruebas de protocolo completas. No se capturó el escritorio.")
    exit(0)
} catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
