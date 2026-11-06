import Foundation
import Network
import dnssd

enum Discovery {
    static let serviceType = "_imacdisplay._tcp"
    static let serviceName = "MacBook"
    static let port: UInt16 = 7777
}

/// Anuncia el emisor solo en la interfaz elegida mientras espera al receptor.
/// NWListener anunciaría en todas las interfaces, incluida Wi‑Fi aunque se haya
/// elegido el cable. El registro TXT contiene solo versión y tipo de enlace.
final class BonjourAdvertiser {
    private var reference: DNSServiceRef?
    var onUpdate: ((DNSServiceErrorType) -> Void)?

    @discardableResult
    func start(interfaceIndex: UInt32, link: LinkKind, port: UInt16 = Discovery.port) -> DNSServiceErrorType {
        stop()
        guard interfaceIndex != 0 else { return DNSServiceErrorType(kDNSServiceErr_BadParam) }
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for (key, value) in [("p", "3"), ("link", link.tag)] {
            _ = value.withCString { TXTRecordSetValue(&record, key, UInt8(strlen($0)), $0) }
        }
        var created: DNSServiceRef?
        let status = DNSServiceRegister(&created, 0, interfaceIndex, Discovery.serviceName, Discovery.serviceType,
            nil, nil, port.bigEndian, TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
            { _, _, error, _, _, _, context in
                guard let context else { return }
                Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue().onUpdate?(error)
            }, Unmanaged.passUnretained(self).toOpaque())
        let ok = DNSServiceErrorType(kDNSServiceErr_NoError)
        guard status == ok, let created else { return status }
        let queued = DNSServiceSetDispatchQueue(created, .main)
        guard queued == ok else { DNSServiceRefDeallocate(created); return queued }
        reference = created
        return status
    }
    func stop() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }
    deinit { stop() }
}

/// Emisores anunciados en la red local o en el cable, para no escribir la IP.
@MainActor final class SenderBrowser {
    struct Found: Equatable {
        let endpoint: NWEndpoint
        let interface: NWInterface?
        let link: LinkKind
        var title: String { "MacBook · \(link.title)" }
    }
    private(set) var found: [Found] = []
    var onChange: (() -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Discovery.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: Diagnostics.shared.event("discovery_ready")
            case .waiting(let error): Diagnostics.shared.failure("discovery_waiting", error: error)
            case .failed(let error): Diagnostics.shared.failure("discovery_failed", error: error)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
    func stop() {
        browser?.browseResultsChangedHandler = nil
        browser?.cancel(); browser = nil
        found = []
    }
    private func update(_ results: Set<NWBrowser.Result>) {
        var list = [Found]()
        for result in results {
            var link = LinkKind.other
            if case .bonjour(let record) = result.metadata, let tag = record["link"] { link = LinkKind(tag: tag) }
            let interface = result.interfaces.first { $0.type != .loopback } ?? result.interfaces.first
            list.append(Found(endpoint: result.endpoint, interface: interface, link: link))
        }
        list.sort { ($0.link, $0.title) < ($1.link, $1.title) }
        guard list != found else { return }
        found = list
        Diagnostics.shared.event("discovery_results", ["count": .count(list.count),
            "usb_cable": .flag(list.contains { $0.link == .usbCable })])
        onChange?()
    }
}
