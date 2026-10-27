import AppKit
import Network

final class ReceiverApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controls: NSWindow!, videoWindow: NSWindow!
    private let host = NSTextField(string: "")
    private let code = NSSecureTextField(string: "")
    private let status = label("Introduce la dirección IP y la clave que muestra la MacBook.")
    private let video = VideoView(frame: .zero)
    private let playback = FrameReceiver()
    private let activity = StreamActivity()
    private var connectButton: NSButton!
    private var channel: PacketChannel?
    private var authorized = false, receivedFirstFrame = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        controls = makeWindow("iMac por red · Receptor", width: 620, height: 390)
        controls.delegate = self
        videoWindow = makeWindow("Pantalla de la MacBook · ⌃⌘F para pantalla completa", width: 1100, height: 650)
        videoWindow.delegate = self; videoWindow.contentView = video
        videoWindow.collectionBehavior = [.fullScreenPrimary]
        playback.render = { [weak self] packet, completion in self?.video.display(packet, completion: completion) }
        playback.onAcknowledged = { [weak self] sequence in
            guard let self else { return }
            self.channel?.send(Wire.ack(sequence))
            if !self.receivedFirstFrame {
                self.receivedFirstFrame = true
                self.activity.start(keepingDisplayAwake: true)
                self.status.stringValue = "Recibiendo pantalla. Para verla completa usa el botón Pantalla completa."
            }
        }
        playback.onError = { [weak self] message in self?.channel?.close(message) }
        host.placeholderString = "Ejemplo: 192.168.1.10"
        code.placeholderString = "Pega la clave temporal completa"
        connectButton = button("Conectar", target: self, action: #selector(connect))
        let actions = NSStackView(views: [connectButton,
            button("Desconectar", target: self, action: #selector(disconnect)),
            button("Pantalla completa", target: self, action: #selector(fullscreen))])
        let stack = NSStackView(views: [label("La pantalla de tu MacBook", size: 25, bold: true),
            label("IP de la MacBook · puerto 7777", bold: true), host,
            label("Clave de emparejamiento", bold: true), code, actions, status,
            label("v0.2.0 · usa el teclado y mouse de la MacBook. Solo video, sin audio ni control remoto. Pulsa Esc para salir de pantalla completa.", size: 12)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: controls.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: controls.contentView!.topAnchor, constant: 26),
            host.widthAnchor.constraint(equalTo: stack.widthAnchor), code.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Vista")
        let full = NSMenuItem(title: "Pantalla completa", action: #selector(fullscreen), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]; full.target = self
        viewMenu.addItem(full); viewMenuItem.submenu = viewMenu; NSApp.mainMenu?.addItem(viewMenuItem)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        controls.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func connect() {
        guard channel == nil else { return }
        do {
            let ip = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLocalIPv4(ip) else { throw DisplayError("Introduce una dirección IPv4 de tu red local.") }
            let parameters = try Pairing.parameters(code: code.stringValue)
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: 7777, using: parameters)
            let peer = PacketChannel(connection)
            channel = peer; authorized = false; receivedFirstFrame = false
            playback.reset(); video.reset()
            connectButton.isEnabled = false; host.isEnabled = false; code.isEnabled = false
            peer.onReady = { [weak self, weak peer] in
                self?.status.stringValue = "Conexión cifrada establecida. Acepta la solicitud en la MacBook."
                peer?.send(Wire.hello)
            }
            peer.onPacket = { [weak self] data in self?.receive(data) }
            peer.onClose = { [weak self] reason in self?.finish(reason) }
            status.stringValue = "Conectando…"
            peer.start()
        } catch { status.stringValue = error.localizedDescription }
    }
    private func receive(_ data: Data) {
        guard let channel else { return }
        if data == Wire.accepted, !authorized {
            authorized = true
            status.stringValue = "Aceptado. Esperando imagen de la MacBook…"
            videoWindow.makeKeyAndOrderFront(nil)
        } else if data == Data([5]), authorized {
            channel.armTimeout(seconds: 10); channel.send(Data([6]))
        } else if data.first == 3, authorized {
            do {
                try playback.receive(VideoPacket(data: data))
            } catch { channel.close(error.localizedDescription) }
        } else { channel.close("El emisor envió un mensaje inesperado.") }
    }
    private func finish(_ message: String) {
        activity.stop()
        channel = nil; authorized = false; receivedFirstFrame = false
        playback.reset(); video.reset(); videoWindow.orderOut(nil)
        status.stringValue = message
        connectButton.isEnabled = true; host.isEnabled = true; code.isEnabled = true
        controls.makeKeyAndOrderFront(nil)
    }
    @objc private func disconnect() { channel?.close("Desconectado. Prepara una nueva sesión en la MacBook para volver a conectar.") }
    @objc private func fullscreen() {
        guard authorized else { status.stringValue = "Conecta primero la MacBook."; return }
        videoWindow.makeKeyAndOrderFront(nil); videoWindow.toggleFullScreen(nil)
    }
    @objc private func sleeping() { channel?.close("Conexión cerrada por reposo. Vuelve a conectar al despertar.") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === videoWindow { disconnect(); return false }
        NSApp.terminate(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) { activity.stop(); channel?.onClose = nil; channel?.close() }
}

let app = NSApplication.shared
let delegate = ReceiverApp()
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
