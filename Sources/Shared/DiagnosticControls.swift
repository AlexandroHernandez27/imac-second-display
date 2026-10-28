import AppKit
import UniformTypeIdentifiers

@MainActor final class DiagnosticControls: NSObject {
    private let role: String
    private weak var window: NSWindow?
    init(role: String, window: NSWindow) { self.role = role; self.window = window; super.init() }

    func makeButton() -> NSButton {
        let menu = NSMenu(title: "Diagnóstico")
        let item = NSMenuItem(title: "Exportar diagnóstico…", action: #selector(export), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        let parent = NSMenuItem(); parent.submenu = menu
        NSApp.mainMenu?.addItem(parent)
        return button("Exportar diagnóstico…", target: self, action: #selector(export))
    }
    @objc private func export() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "iMac-\(role)-diagnostico.txt"
        panel.message = "Guarda el registro de esta app para revisar el fallo. No incluye IP, claves ni imágenes. No se envía automáticamente."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                Diagnostics.shared.event("diagnostic_export")
                let report = try Diagnostics.shared.report()
                try report.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                let alert = NSAlert()
                alert.messageText = "No se pudo exportar el diagnóstico"
                alert.informativeText = "Comprueba que puedes guardar archivos en esa carpeta y que hay espacio disponible."
                alert.beginSheetModal(for: window)
            }
        }
    }
}
