import AppKit
import Network

struct DisplayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func requireSuccess(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw DisplayError("\(operation): error \(status)") }
}
func isLocalIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4, IPv4Address(address) != nil else { return false }
    return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
        || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
}
func localAddresses() -> [String] {
    var result = [String]()
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return [] }
    defer { freeifaddrs(interfaces) }
    var cursor = interfaces
    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if isLocalIPv4(ip) { result.append(ip) }
        }
    }
    return Array(Set(result)).sorted()
}
extension Data {
    mutating func put32(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw DisplayError("Mensaje incompleto.") }
        return self[index(startIndex, offsetBy: offset)..<index(startIndex, offsetBy: offset + 4)]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
func label(_ text: String, size: CGFloat = 14, bold: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    return field
}
func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let result = NSButton(title: title, target: target, action: action)
    result.bezelStyle = .rounded
    return result
}
func makeWindow(_ title: String, width: CGFloat, height: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.center()
    return window
}
func configureMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let submenu = NSMenu()
    submenu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = submenu
    menu.addItem(appItem)
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Editar")
    editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApplication.shared.mainMenu = menu
}
