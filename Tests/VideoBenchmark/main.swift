import AppKit
import VideoToolbox

import CoreText

@MainActor final class Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var completion: ((Result<Void, Error>) -> Void)?
    private(set) var lastSource = 0
    private(set) var lastImage: CVPixelBuffer?

    func decode(_ packet: VideoPacket, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            if session == nil {
                format = try packet.formatDescription()
                var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                    guard let refcon else { return }
                    let owner = Unmanaged<Decoder>.fromOpaque(refcon).takeUnretainedValue()
                    var marker = 0
                    if let image {
                        CVPixelBufferLockBaseAddress(image, .readOnly)
                        if let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) {
                            let row = CVPixelBufferGetBytesPerRow(image)
                            for bit in 0..<12 {
                                if base[56 * row + (32 + bit * 16 + 8) * 4] > 128 { marker |= 1 << bit }
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(image, .readOnly)
                    }
                    let decodedMarker = marker
                    let valid = status == noErr && image != nil
                    DispatchQueue.main.async {
                        let done = owner.completion; owner.completion = nil
                        owner.lastSource = decodedMarker
                        if let image { owner.lastImage = image }
                        done?(valid ? .success(()) : .failure(DisplayError("Falló la decodificación: \(status)")))
                    }
                }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                try requireSuccess(VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: nil,
                    imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                    outputCallback: &callback, decompressionSessionOut: &session), "Crear decoder")
            }
            self.completion = completion
            let sample = try packet.sampleBuffer(format: format!)
            try requireSuccess(VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil), "Decodificar")
        } catch { self.completion = nil; completion(.failure(error)) }
    }
    func stop() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil }
}

func image(pool: CVPixelBufferPool, marker: Int) throws -> CVPixelBuffer {
    var output: CVPixelBuffer?
    try requireSuccess(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output), "Crear imagen sintética")
    guard let output else { throw DisplayError("No se creó la imagen") }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(output)
    memset(base, 80, row * CVPixelBufferGetHeight(output))
    // Marcador visual verificable después de compresión con pérdidas.
    for bit in 0..<12 {
        let value: Int32 = marker & (1 << bit) == 0 ? 20 : 230
        for y in 40..<72 { memset(base + y * row + (32 + bit * 16) * 4, value, 16 * 4) }
    }
    let x = 320 + marker * 7 % 1000
    for y in 120..<600 { memset(base + y * row + x * 4, 210, 48 * 4) }
    return output
}

@MainActor func snapshot(_ pipeline: CapturePipeline) async -> VideoMetrics {
    await withCheckedContinuation { continuation in pipeline.metrics { continuation.resume(returning: $0) } }
}

@MainActor func benchmark(window: Int, delayMS: Int, lowLatency: Bool = true, realTime: Bool = true) async throws -> Double {
    let pipeline = CapturePipeline(window: window)
    let decoder = Decoder()
    let receiver = FrameReceiver()
    var failure: String?
    var delivered = 0
    var sourceTimes: [Int: Double] = [:]
    var decodedMS: [Double] = []
    receiver.render = { packet, completion in
        decoder.decode(packet) { result in
            if case .success = result, decoder.lastSource > 30, let start = sourceTimes[decoder.lastSource] {
                decodedMS.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            completion(result)
        }
    }
    receiver.onError = { failure = $0 }
    receiver.onAcknowledged = { sequence in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMS)) {
            delivered += 1
            pipeline.acknowledge(sequence)
        }
    }
    pipeline.onFrame = { data, _ in
        do { try receiver.receive(VideoPacket(data: data)) }
        catch { failure = error.localizedDescription }
    }
    pipeline.onError = { failure = $0 }
    do {
        try pipeline.startSynthetic(width: 1920, height: 1080, fps: 60, bitrate: 12_000_000, lowLatency: lowLatency, realTime: realTime)
        var pool: CVPixelBufferPool?
        try requireSuccess(CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferWidthKey: 1920,
            kCVPixelBufferHeightKey: 1080, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool), "Crear pool")
        guard let pool else { throw DisplayError("Pool ausente") }
        let count = 180
        let start = ProcessInfo.processInfo.systemUptime
        for index in 1...count {
            let deadline = start + Double(index - 1) / 60
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            if let failure { throw DisplayError(failure) }
            let pixel = try image(pool: pool, marker: index)
            sourceTimes[index] = ProcessInfo.processInfo.systemUptime
            pipeline.submitSynthetic(pixel, pts: CMTime(value: Int64(index), timescale: 60))
        }
        let moving = await snapshot(pipeline)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var drained = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let failure { throw DisplayError(failure) }
            let sample = await snapshot(pipeline)
            if sample.inFlight == 0 && !sample.waitingLatest && decoder.lastSource == count { drained = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard drained else { throw DisplayError("No llegó el último cambio al detenerse la fuente (marcador \(decoder.lastSource)/\(count)).") }
        print(String(format: "Ventana %d · ACK artificial %d ms · captura %.1f FPS · entrega %.1f FPS · preparación %.1f ms · ACK medido %.1f ms · última imagen %d/%d · total %d",
            window, delayMS, moving.capturedFPS, moving.deliveredFPS, moving.preparationMS ?? 0, moving.ackMS ?? 0, decoder.lastSource, count, delivered))
        let sorted = decodedMS.sorted()
        if !sorted.isEmpty {
            print(String(format: "  LLRC %@ · RealTime %@ · entrada→decodificada mediana %.2f ms · p95 %.2f ms (sin red, sin panel)",
                String(lowLatency), String(realTime), sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]))
        }
        await pipeline.stop(); decoder.stop()
        return moving.deliveredFPS
    } catch { await pipeline.stop(); decoder.stop(); throw error }
}

/// Página de texto real (negro sobre blanco), como un documento o código.
func textImage(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
    var output: CVPixelBuffer?
    try requireSuccess(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output), "Crear página")
    guard let output else { throw DisplayError("Página ausente") }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(output), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw DisplayError("Contexto ausente") }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let words = ["pantalla", "iMac", "func", "let", "VTCompression", "latencia", "cable", "USB", "fluidez", "píxel",
                 "MacBook", "return", "struct", "0x1f", "42", "árbol", "ñandú", "{", "}", "->", "Data()", "while"]
    var state = UInt64(seed * 7919 + 17), text = ""
    func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
    for line in 0..<(height / 16) {
        text += "\(line + seed * 100) "
        for _ in 0..<(10 + next() % 14) { text += words[next() % words.count] + " " }
        text += "\n"
    }
    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: 24, y: 0, width: width - 48, height: height), transform: nil), nil), context)
    return output
}

func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let width = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b)), height = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
    var squared = 0.0
    for y in 0..<height { for x in 0..<width { for c in 0..<3 {
        let d = Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c]); squared += d * d
    } } }
    return 10 * log10(255 * 255 / max(1e-9, squared / Double(width * height * 3)))
}

/// Nitidez final de una pantalla que queda quieta tras un cambio. Sin refinar,
/// ScreenCaptureKit no envía más imágenes y la iMac conserva esa calidad.
@MainActor func stillQuality(refinement: Bool, sources: [CVPixelBuffer], bitrate: Int) async throws -> (psnr: Double, refined: Int) {
    let pipeline = CapturePipeline(window: 3, refinement: refinement)
    let decoder = Decoder()
    let receiver = FrameReceiver()
    var failure: String?
    var refined = 0
    receiver.render = { packet, completion in decoder.decode(packet, completion: completion) }
    receiver.onAcknowledged = { pipeline.acknowledge($0) }
    receiver.onError = { failure = $0 }
    pipeline.onFrame = { data, _ in
        do { try receiver.receive(VideoPacket(data: data)) } catch { failure = error.localizedDescription }
    }
    pipeline.onError = { failure = $0 }
    defer { decoder.stop() }
    let width = CVPixelBufferGetWidth(sources[0]), height = CVPixelBufferGetHeight(sources[0])
    try pipeline.startSynthetic(width: width, height: height, fps: 60, bitrate: bitrate)
    let start = ProcessInfo.processInfo.systemUptime
    for (index, source) in sources.enumerated() {
        let remaining = start + Double(index) / 60 - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        pipeline.submitSynthetic(source, pts: .invalid)
    }
    // Margen para el refinamiento: tres intervalos quietos y hasta ocho cuadros.
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let failure { await pipeline.stop(); throw DisplayError(failure) }
        let sample = await snapshot(pipeline)
        refined = max(refined, sample.refinedFrames)
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let final = await snapshot(pipeline)
    await pipeline.stop()
    guard final.inFlight == 0, let image = decoder.lastImage else { throw DisplayError("La imagen quieta no terminó de llegar.") }
    return (psnr(image, sources.last!), refined)
}

/// Decoder de producción del receptor, ACK al terminar de decodificar, 1440p/60.
@MainActor func productionReceiver(width: Int, height: Int, bitrate: Int) async throws {
    let pipeline = CapturePipeline(window: 3)
    let decoder = VideoDecoder()
    let receiver = FrameReceiver()
    var statistics = DecodeStatistics(now: ProcessInfo.processInfo.systemUptime)
    var failure: String?
    var format: CMVideoFormatDescription?
    var parameterSets = Data()
    receiver.render = { packet, completion in
        do {
            if format == nil || packet.sps + packet.pps != parameterSets {
                format = try packet.formatDescription(); parameterSets = packet.sps + packet.pps
                try decoder.prepare(format: format!)
            }
            decoder.decode(try packet.sampleBuffer(format: format!)) { result in
                switch result {
                case .success(let (_, milliseconds)):
                    statistics.shown(at: ProcessInfo.processInfo.systemUptime, decodeMS: milliseconds)
                    completion(.success(()))
                case .failure(let error): completion(.failure(error))
                }
            }
        } catch { completion(.failure(error)) }
    }
    receiver.onAcknowledged = { pipeline.acknowledge($0) }
    receiver.onError = { failure = $0 }
    pipeline.onFrame = { data, _ in
        do { try receiver.receive(VideoPacket(data: data)) } catch { failure = error.localizedDescription }
    }
    pipeline.onError = { failure = $0 }
    defer { decoder.invalidate() }
    try pipeline.startSynthetic(width: width, height: height, fps: 60, bitrate: bitrate)
    var pool: CVPixelBufferPool?
    try requireSuccess(CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool), "Crear pool")
    guard let pool else { throw DisplayError("Pool ausente") }
    let start = ProcessInfo.processInfo.systemUptime
    for index in 1...180 {
        let remaining = start + Double(index - 1) / 60 - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        if let failure { await pipeline.stop(); throw DisplayError(failure) }
        pipeline.submitSynthetic(try image(pool: pool, marker: index), pts: .invalid)
    }
    let moving = await snapshot(pipeline)
    let shown = statistics.snapshot(at: ProcessInfo.processInfo.systemUptime)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let drained = await snapshot(pipeline)
    await pipeline.stop()
    if let failure { throw DisplayError(failure) }
    let hardware = decoder.hardware.map { $0 ? "hardware" : "software" } ?? "sin confirmar"
    print(String(format: "Receptor de producción · %d×%d · %d Mbps · captura %.1f · entrega %.1f · mostrados %.1f FPS · decodificación %@ media %.2f ms · ACK %.1f ms",
        width, height, bitrate / 1_000_000, moving.capturedFPS, moving.deliveredFPS, shown.fps, hardware, shown.decodeMS ?? 0, moving.ackMS ?? 0))
    guard moving.deliveredFPS > 50, shown.fps > 50, drained.inFlight == 0 else {
        throw DisplayError("El receptor de producción no sostuvo 1440p a 60 FPS en este equipo.")
    }
}

Task { @MainActor in
    let activity = StreamActivity()
    activity.start(keepingDisplayAwake: false)
    do {
        if CommandLine.arguments.contains("--compare-encoder") {
            // Dos rondas en orden inverso; misma fuente y receptor en cada caso.
            for modes in [[(true, true), (false, true), (false, false)], [(false, false), (false, true), (true, true)]] {
                for (lowLatency, realTime) in modes {
                    _ = try await benchmark(window: 3, delayMS: 7, lowLatency: lowLatency, realTime: realTime)
                }
            }
            activity.stop()
            print("PASS: comparación del encoder completada; no demuestra latencia de Wi‑Fi ni del panel.")
            exit(0)
        }
        _ = try await benchmark(window: 1, delayMS: 7)
        let normal = try await benchmark(window: 3, delayMS: 7)
        let blocked = try await benchmark(window: 1, delayMS: 40)
        let pipelined = try await benchmark(window: 3, delayMS: 40)
        guard normal > 45, pipelined > blocked * 1.5 else { throw DisplayError("La prueba no demostró la mejora de capacidad esperada.") }
        print("PASS: encoder y decoder reales, ventana acotada y última actualización después de parar la fuente. Demora simulada, no Wi‑Fi real ni medición del panel.")
        try await productionReceiver(width: 2560, height: 1440, bitrate: 40_000_000)
        print("PASS: decoder de producción con ACK tras decodificar sostiene 1440p a 60 FPS en esta Mac (no mide la iMac).")
        // Inicio de sesión con el escritorio quieto: un único IDR.
        let page = try textImage(width: 2560, height: 1440, seed: 1)
        let plain = try await stillQuality(refinement: false, sources: [page], bitrate: 40_000_000)
        let refined = try await stillQuality(refinement: true, sources: [page], bitrate: 40_000_000)
        print(String(format: "Texto quieto tras el primer cuadro · sin refinar %.2f dB · refinado %.2f dB (%d cuadros extra)", plain.psnr, refined.psnr, refined.refined))
        // Cambio brusco a otra página y quietud.
        let other = try textImage(width: 2560, height: 1440, seed: 2)
        let sequence = Array(repeating: page, count: 20) + [other]
        let plainChange = try await stillQuality(refinement: false, sources: sequence, bitrate: 40_000_000)
        let refinedChange = try await stillQuality(refinement: true, sources: sequence, bitrate: 40_000_000)
        print(String(format: "Texto quieto tras cambiar de página · sin refinar %.2f dB · refinado %.2f dB (%d cuadros extra)", plainChange.psnr, refinedChange.psnr, refinedChange.refined))
        guard refined.psnr >= plain.psnr + 1.5, refinedChange.psnr >= plainChange.psnr - 0.1, refined.refined <= CapturePipeline.refinementLimit else {
            throw DisplayError("El refinamiento no mejoró la nitidez de la pantalla quieta.")
        }
        print("PASS: refinamiento acotado mejora el texto quieto y se detiene solo. PSNR con conversión de color; no mide el panel.")
        activity.stop()
        exit(0)
    } catch { activity.stop(); print("FAIL: \(error.localizedDescription)"); exit(1) }
}
dispatchMain()
