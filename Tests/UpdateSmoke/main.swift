import AppKit

@MainActor final class UpdateTestApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var updates: AppUpdater!
    private var connected = false
    private var simulation: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        updates = AppUpdater(isConnected: { [weak self] in self?.connected == true })
        window = makeWindow("Prueba aislada del actualizador", width: 660, height: 220)
        simulation = NSButton(checkboxWithTitle: "Simular sesión de pantalla", target: self, action: #selector(toggleSession))
        let stack = NSStackView(views: [label("Prueba de actualización · versión \(appVersion)", size: 23, bold: true),
            label("Esta app de prueba no captura ni transmite el escritorio."), simulation, updates.controls])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.frame = NSRect(x: 24, y: 24, width: 610, height: 175)
        window.contentView?.addSubview(stack)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleSession() {
        if simulation.state == .on {
            guard updates.mayConnect() else { simulation.state = .off; return }
            connected = true
        } else { connected = false; updates.sessionEnded() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { UpdateTestApp() }
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
