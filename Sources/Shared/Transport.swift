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

// Todos los callbacks se serializan en main. Máximo un paquete de video en vuelo,
// con ACK de aplicación antes de codificar otro fotograma.
final class PacketChannel {
    static let maximumPacket = 8 * 1024 * 1024
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onPacket: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private var timeout: DispatchWorkItem?

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        armTimeout(seconds: 12)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.armTimeout(seconds: 60)
                self.readHeader()
                self.onReady?()
            case .failed(let error): self.close("No se pudo conectar: \(error.localizedDescription). Revisa IP y clave.")
            case .cancelled: self.close("Conexión cerrada.")
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func armTimeout(seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close("La conexión dejó de responder. Vuelve a conectar.") }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func send(_ payload: Data) {
        guard !closed, !payload.isEmpty, payload.count <= Self.maximumPacket else { return }
        var packet = Data()
        packet.put32(UInt32(payload.count)); packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.close("Error al enviar: \(error.localizedDescription)") }
        })
    }
    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == 4,
                  let length = try? data.uint32(at: 0), length > 0, length <= Self.maximumPacket else {
                self.close(done ? "El otro equipo se desconectó." : "Cabecera de red inválida."); return
            }
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] data, _, _, error in
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == length else { self.close("Mensaje de red incompleto."); return }
                self.onPacket?(data)
                if !self.closed { self.readHeader() }
            }
        }
    }
    func close(_ reason: String = "Desconectado.") {
        guard !closed else { return }
        closed = true; timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onPacket = nil; onClose = nil
        callback?(reason)
    }
    deinit { timeout?.cancel(); connection.cancel() }
}

enum Wire {
    static let hello = Data([1, 73, 83, 68, 1]) // ISD versión 1
    static let accepted = Data([2])
    static func ack(_ sequence: UInt32) -> Data { var data = Data([4]); data.put32(sequence); return data }
}
