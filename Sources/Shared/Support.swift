import AppKit
import Network

var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "desarrollo" }
var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "desarrollo" }

struct DisplayError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func requireSuccess(_ status: OSStatus, _ operation: String) throws {
    if status != noErr {
        Diagnostics.shared.event("system_operation_failed", ["osstatus": .count(Int(status))])
        throw DisplayError("\(operation): error \(status)")
    }
}
func isLocalIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4, IPv4Address(address) != nil else { return false }
    return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
        || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
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
