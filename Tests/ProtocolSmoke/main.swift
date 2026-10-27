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
    let serverCode = try Pairing.generate()
    let params = try Pairing.parameters(code: serverCode)
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: params)
    var ready = false, received = false, acknowledged = false, closed = false
    var server: PacketChannel?, client: PacketChannel?
    var failure: String?
    listener.stateUpdateHandler = { state in
        if case .ready = state { ready = true }
        if case .failed(let error) = state { failure = error.localizedDescription }
    }
    listener.newConnectionHandler = { connection in
        let peer = PacketChannel(connection); server = peer
        peer.onPacket = { data in
            if data == Wire.hello { peer.send(Wire.accepted); peer.send(payload) }
            else if data == Wire.ack(1) { acknowledged = true }
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
        if data == payload { received = true; peer.send(Wire.ack(1)) }
        else { failure = "El video recibido cambió" }
    }
    peer.onClose = { _ in closed = true }
    peer.start()
    if wrongKey {
        try check(waitFor(15) { closed || received } && closed && !received, "Se aceptó una clave incorrecta")
        print("PASS: clave incorrecta rechazada sin entregar video.")
    } else {
        try check(waitFor(10) { acknowledged || failure != nil || closed } && received && acknowledged, failure ?? "Falló TLS/entrega/ACK")
        print("PASS: TLS-PSK local → H.264 íntegro → ACK.")
    }
}

do {
    try check(isLocalIPv4("192.168.1.2") && isLocalIPv4("10.0.0.2") && !isLocalIPv4("8.8.8.8") && !isLocalIPv4("192.168.1.999"), "Filtro LAN inválido")
    try check(rejects { _ = try Pairing.parameters(code: "123456") }, "Aceptó una clave débil")
    let payload = try testCodec()
    try testNetwork(payload: payload, wrongKey: false)
    try testNetwork(payload: payload, wrongKey: true)
    print("PASS: pruebas de protocolo completas. No se capturó el escritorio.")
    exit(0)
} catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
