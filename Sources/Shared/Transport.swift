import Foundation
import Network
import Security

enum Pairing {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        try requireSuccess(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "Generar clave")
        return Data(bytes).base64EncodedString()
    }
    static func parameters(code: String) throws -> NWParameters {
        guard let key = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), key.count == 32 else {
            throw DisplayError("Pega la clave completa que aparece en la MacBook.")
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let identity = Data("imac-second-display-v1".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(options,
                    DispatchData(bytes: keyBytes) as dispatch_data_t,
                    DispatchData(bytes: identityBytes) as dispatch_data_t)
            }
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

// Callbacks serializados en main. El emisor acota a tres fotogramas pendientes
// con un receptor v2; un receptor v1 conserva la ventana de uno.
final class PacketChannel {
    static let maximumPacket = 8 * 1024 * 1024
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onPacket: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private var timeout: DispatchWorkItem?
    private var ready = false
    private var sentPackets = 0, receivedPackets = 0

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        Diagnostics.shared.event("transport_start")
        armTimeout(seconds: 12)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .setup: Diagnostics.shared.event("transport_setup")
            case .preparing: Diagnostics.shared.event("transport_preparing")
            case .waiting(let error): Diagnostics.shared.failure("transport_waiting", error: error)
            case .ready:
                self.ready = true
                Diagnostics.shared.event("tls_ready")
                self.armTimeout(seconds: 60)
                self.readHeader()
                self.onReady?()
            case .failed(let error):
                Diagnostics.shared.failure("transport_failed", error: error)
                self.close("No se pudo conectar: \(error.localizedDescription). Revisa IP y clave.", cause: "network_failed")
            case .cancelled: self.close("Conexión cerrada.", cause: "network_cancelled")
            default: break
            }
        }
        connection.pathUpdateHandler = { path in
            Diagnostics.shared.event("network_path", ["satisfied": .flag(path.status == .satisfied),
                "wifi": .flag(path.usesInterfaceType(.wifi)), "ethernet": .flag(path.usesInterfaceType(.wiredEthernet)),
                "loopback": .flag(path.usesInterfaceType(.loopback)), "expensive": .flag(path.isExpensive),
                "constrained": .flag(path.isConstrained)])
        }
        connection.viabilityUpdateHandler = { Diagnostics.shared.event("network_viability", ["viable": .flag($0)]) }
        connection.start(queue: .main)
    }
    func armTimeout(seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Diagnostics.shared.event("transport_timeout", ["seconds": .measure(seconds)])
            self?.close("La conexión dejó de responder. Vuelve a conectar y exporta el diagnóstico de ambas apps.", cause: "timeout")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func send(_ payload: Data) {
        guard !closed, !payload.isEmpty, payload.count <= Self.maximumPacket else { return }
        var packet = Data()
        packet.put32(UInt32(payload.count)); packet.append(payload)
        sentPackets += 1
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error {
                Diagnostics.shared.failure("transport_send_error", error: error)
                self.close("Error al enviar: \(error.localizedDescription)", cause: "send_error")
            }
        })
    }
    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let error {
                Diagnostics.shared.failure("transport_header_error", error: error)
                self.close("Error de red al recibir: \(error.localizedDescription). Exporta el diagnóstico de ambas apps.", cause: "header_error")
                return
            }
            guard let data, data.count == 4,
                  let length = try? data.uint32(at: 0), length > 0, length <= Self.maximumPacket else {
                Diagnostics.shared.event("transport_header_incomplete", ["bytes": .count(data?.count ?? 0), "eof": .flag(done)])
                self.close(done ? "El otro equipo cerró la conexión. Revisa el mensaje en esa Mac y exporta el diagnóstico de ambas apps." : "Cabecera de red inválida.", cause: "header_incomplete"); return
            }
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                if let error {
                    Diagnostics.shared.failure("transport_payload_error", error: error)
                    self.close("Error de red al recibir el mensaje: \(error.localizedDescription)", cause: "payload_error"); return
                }
                guard let data, data.count == length else {
                    Diagnostics.shared.event("transport_payload_incomplete", ["bytes": .count(data?.count ?? 0), "expected": .count(Int(length)), "eof": .flag(done)])
                    self.close("Mensaje de red incompleto.", cause: "payload_incomplete"); return
                }
                self.receivedPackets += 1
                self.onPacket?(data)
                if !self.closed { self.readHeader() }
            }
        }
    }
    func close(_ reason: String = "Desconectado.", cause: StaticString = "local_close") {
        guard !closed else { return }
        Diagnostics.shared.event("transport_close", ["cause": .tag(cause), "tls_ready": .flag(ready),
            "sent_packets": .count(sentPackets), "received_packets": .count(receivedPackets)])
        closed = true; timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil; connection.viabilityUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onPacket = nil; onClose = nil
        callback?(reason)
    }
    deinit { timeout?.cancel(); connection.cancel() }
}

enum Wire {
    static let helloV1 = Data([1, 73, 83, 68, 1])
    static let hello = Data([1, 73, 83, 68, 2]) // ISD v2: receptor con cola acotada
    static let accepted = Data([2])
    static func frameWindow(forHello data: Data) -> Int? {
        if data == hello { return 3 }
        if data == helloV1 { return 1 }
        return nil
    }
    static func ack(_ sequence: UInt32) -> Data { var data = Data([4]); data.put32(sequence); return data }
}
