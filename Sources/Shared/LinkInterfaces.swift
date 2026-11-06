import Foundation
import IOKit
import SystemConfiguration

/// Tipo de enlace local, ordenado por preferencia para una pantalla fluida.
/// El cable USB es la función de red CDC-NCM que macOS expone en los puertos
/// USB-C de una Mac con Apple Silicon cuando el otro extremo es un host USB,
/// como un puerto USB-A de la iMac. Ver docs/CABLE_USB.md.
enum LinkKind: Int, CaseIterable, Comparable {
    case usbCable = 0, thunderbolt, ethernet, wifi, other

    static func < (lhs: LinkKind, rhs: LinkKind) -> Bool { lhs.rawValue < rhs.rawValue }
    init(tag: String) { self = LinkKind.allCases.first { $0.tag == tag } ?? .other }
    /// Valor del registro TXT de Bonjour; no identifica al equipo.
    var tag: String {
        switch self {
        case .usbCable: return "usb"
        case .thunderbolt: return "thunderbolt"
        case .ethernet: return "ethernet"
        case .wifi: return "wifi"
        case .other: return "other"
        }
    }
    var title: String {
        switch self {
        case .usbCable: return "Cable USB"
        case .thunderbolt: return "Thunderbolt"
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi‑Fi"
        case .other: return "Red local"
        }
    }
    var diagnosticTag: StaticString {
        switch self {
        case .usbCable: return "usb_cable"
        case .thunderbolt: return "thunderbolt"
        case .ethernet: return "ethernet"
        case .wifi: return "wifi"
        case .other: return "other"
        }
    }
    /// Enlaces sin retransmisiones de radio: admiten 1440p/60 y bitrate alto.
    var isWired: Bool { self != .wifi && self != .other }
}

struct LocalLink: Equatable {
    let name: String
    let kind: LinkKind
    let ipv4: String?
    /// Incluye el ámbito, por ejemplo `fe80::1%en6`. Disponible al instante en
    /// un cable directo; la IPv4 169.254.x.x tarda unos 20 s en asignarse.
    let ipv6LinkLocal: String?
    let speedMbps: Int?

    var bindHosts: [String] { [ipv4, ipv6LinkLocal].compactMap { $0 } }
    var interfaceIndex: UInt32 { if_nametoindex(name) }
    var speedLabel: String? {
        guard let speedMbps, kind == .usbCable else { return nil }
        switch speedMbps {
        case ..<480: return "USB 1.1"
        case 480: return "USB 2.0 · 480 Mbps"
        default: return "USB 3 · \(speedMbps / 1000) Gbps"
        }
    }
    var menuTitle: String {
        var parts = [kind.title, ipv4 ?? "IPv4 en unos segundos"]
        if let speedLabel { parts.append(speedLabel) }
        return parts.joined(separator: " · ")
    }
}

enum LinkInventory {
    private static let store = SCDynamicStoreCreate(nil, "iMacSecondDisplay" as CFString, nil, nil)

    /// Interfaces activas con dirección local útil, primero la preferida.
    static func current() -> [LocalLink] {
        let addresses = interfaceAddresses()
        let usb = usbCableSpeeds()
        let types = interfaceTypes()
        var links = [LocalLink]()
        for (name, entry) in addresses {
            if let store, let active = linkActive(store, name), !active { continue }
            let kind: LinkKind
            if usb.keys.contains(name) { kind = .usbCable }
            else if name.hasPrefix("bridge") { kind = .thunderbolt }
            else if types[name] == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = .wifi }
            else if types[name] == (kSCNetworkInterfaceTypeEthernet as String) { kind = .ethernet }
            else { kind = .other }
            // Wi‑Fi o Ethernet sin IPv4 privada no tienen LAN útil. Los cables
            // directos sirven desde el primer momento con IPv6 link-local.
            let directCable = kind == .usbCable || kind == .thunderbolt
            guard entry.ipv4 != nil || (directCable && entry.ipv6 != nil) else { continue }
            links.append(LocalLink(name: name, kind: kind, ipv4: entry.ipv4, ipv6LinkLocal: entry.ipv6,
                                   speedMbps: usb[name] ?? nil))
        }
        return links.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    /// Clasifica una interfaz por nombre BSD; útil para diagnosticar el receptor.
    static func kind(ofInterfaceNamed name: String) -> LinkKind {
        if usbCableSpeeds().keys.contains(name) { return .usbCable }
        if name.hasPrefix("bridge") { return .thunderbolt }
        let type = interfaceTypes()[name]
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return .wifi }
        if type == (kSCNetworkInterfaceTypeEthernet as String) { return .ethernet }
        return .other
    }

    private static func interfaceAddresses() -> [String: (ipv4: String?, ipv6: String?)] {
        var result = [String: (ipv4: String?, ipv6: String?)]()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: item.pointee.ifa_name)
            let flags = Int32(item.pointee.ifa_flags)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"), let address = item.pointee.ifa_addr,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            var entry = result[name] ?? (nil, nil)
            if family == AF_INET, entry.ipv4 == nil, isLocalIPv4(text) { entry.ipv4 = text }
            if family == AF_INET6, entry.ipv6 == nil, text.lowercased().hasPrefix("fe80:"), text.contains("%") { entry.ipv6 = text }
            result[name] = entry
        }
        return result
    }

    private static func interfaceTypes() -> [String: String] {
        var types = [String: String]()
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
               let type = SCNetworkInterfaceGetInterfaceType(interface) as String? { types[name] = type }
        }
        return types
    }

    private static func linkActive(_ store: SCDynamicStore, _ name: String) -> Bool? {
        let key = "State:/Network/Interface/\(name)/Link" as CFString
        return (SCDynamicStoreCopyValue(store, key) as? [String: Any])?["Active"] as? Bool
    }

    /// Interfaces Ethernet públicas de un enlace USB Mac a Mac y su velocidad en
    /// Mbps, si se conoce. Lado MacBook: `AppleUSBDeviceNCM*` sobre el controlador
    /// en modo dispositivo. Lado iMac: `AppleUSBNCM*` sobre un dispositivo Apple
    /// llamado «Mac». Las interfaces privadas `anpi*` del sistema se excluyen.
    static func usbCableSpeeds() -> [String: Int?] {
        var result = [String: Int?]()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let name = property(service, "BSD Name") as? String, name.hasPrefix("en") else { continue }
            var entry = service
            IOObjectRetain(entry)
            var deviceSide = false, hostSide = false
            var matched = false
            var speed: Int?
            for _ in 0..<12 {
                var parent: io_registry_entry_t = IO_OBJECT_NULL
                guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
                IOObjectRelease(entry)
                entry = parent
                let type = className(entry)
                if type.hasPrefix("AppleUSBDeviceNCM") { deviceSide = true }
                if type.hasPrefix("AppleUSBNCM") { hostSide = true }
                if deviceSide, let state = property(entry, "CurrentState") as? [String: Any] {
                    matched = true
                    speed = deviceSpeed(state["ConnectionSpeedDescription"] as? String)
                    break
                }
                if hostSide, let vendor = property(entry, "idVendor") as? Int {
                    let product = property(entry, "USB Product Name") as? String ?? property(entry, "kUSBProductString") as? String
                    matched = vendor == 0x05AC && product == "Mac"
                    speed = hostSpeed(property(entry, "USBSpeed") as? Int)
                    break
                }
            }
            IOObjectRelease(entry)
            // updateValue conserva la clave aunque la velocidad sea desconocida.
            if matched { result.updateValue(speed, forKey: name) }
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func className(_ entry: io_registry_entry_t) -> String {
        (IOObjectCopyClass(entry)?.takeRetainedValue() as String?) ?? ""
    }
    /// «High Speed (480 Mbps)», «Super Speed (5 Gbps)», «Super Speed Plus (10 Gbps)».
    static func deviceSpeed(_ description: String?) -> Int? {
        guard let description, let open = description.lastIndex(of: "("), let close = description.lastIndex(of: ")"), open < close else { return nil }
        let parts = description[description.index(after: open)..<close].split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        switch parts[1] {
        case "Mbps": return Int(value)
        case "Gbps": return Int(value * 1000)
        default: return nil
        }
    }
    /// IOUSBHostDevice «USBSpeed»: 1 Full, 2 Low, 3 High, 4 Super, 5 SuperPlus, 6 SuperPlusBy2.
    static func hostSpeed(_ value: Int?) -> Int? {
        switch value {
        case 1: return 12
        case 2: return 1
        case 3: return 480
        case 4: return 5000
        case 5: return 10000
        case 6: return 20000
        default: return nil
        }
    }
}
