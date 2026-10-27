import AppKit
import VideoToolbox

@MainActor final class Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var completion: ((Result<Void, Error>) -> Void)?
    private(set) var lastSource = 0

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
        activity.stop()
        exit(0)
    } catch { activity.stop(); print("FAIL: \(error.localizedDescription)"); exit(1) }
}
dispatchMain()
