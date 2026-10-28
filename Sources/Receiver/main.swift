import AppKit
import Network

@MainActor final class ReceiverApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controls: NSWindow!, videoWindow: NSWindow!
    private var updates: AppUpdater!
    private var diagnostics: DiagnosticControls!
    private var receivedFrames = 0, acknowledgedFrames = 0
    private var lastDiagnosticMetrics = 0.0
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
        Diagnostics.shared.configure(role: "Receiver")
        configureMenu()
        updates = AppUpdater(isConnected: { [weak self] in self?.channel != nil })
        controls = makeWindow("iMac Receiver · v\(appVersion) (\(appBuild))", width: 650, height: 510)
        controls.delegate = self
        diagnostics = DiagnosticControls(role: "Receiver", window: controls)
        videoWindow = makeWindow("Pantalla de la MacBook · ⌃⌘F para pantalla completa", width: 1100, height: 650)
        videoWindow.delegate = self; videoWindow.contentView = video
        videoWindow.collectionBehavior = [.fullScreenPrimary]
        playback.render = { [weak self] packet, completion in self?.video.display(packet, completion: completion) }
        playback.onAcknowledged = { [weak self] sequence in
            guard let self else { return }
            self.channel?.send(Wire.ack(sequence))
            self.acknowledgedFrames += 1
            if !self.receivedFirstFrame {
                Diagnostics.shared.event("first_video_enqueued")
                self.receivedFirstFrame = true
                self.activity.start(keepingDisplayAwake: true)
                self.status.stringValue = "Recibiendo pantalla. Para verla completa usa el botón Pantalla completa."
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastDiagnosticMetrics >= 5 {
                self.lastDiagnosticMetrics = now
                Diagnostics.shared.event("receiver_metrics", ["received_frames": .count(self.receivedFrames), "enqueued_frames": .count(self.acknowledgedFrames), "queue": .count(self.playback.count)])
            }
        }
        playback.onError = { [weak self] message in self?.channel?.close(message, cause: "playback_error") }
        host.placeholderString = "Ejemplo: 192.168.1.10"
        code.placeholderString = "Pega la clave temporal completa"
        connectButton = button("Conectar", target: self, action: #selector(connect))
        let actions = NSStackView(views: [connectButton,
            button("Desconectar", target: self, action: #selector(disconnect)),
            button("Pantalla completa", target: self, action: #selector(fullscreen))])
        let stack = NSStackView(views: [label("La pantalla de tu MacBook", size: 25, bold: true),
            label("IP de la MacBook · puerto 7777", bold: true), host,
            label("Clave de emparejamiento", bold: true), code, actions, status,
            updates.controls,
            diagnostics.makeButton(),
            label("v\(appVersion) · las actualizaciones requieren tu confirmación. Usa el teclado y mouse de la MacBook. Sin audio. Esc sale de pantalla completa.", size: 12)])
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
        guard updates.mayConnect() else { return }
        guard channel == nil else { return }
        Diagnostics.shared.beginSession()
        Diagnostics.shared.event("connect_requested")
        do {
            let ip = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLocalIPv4(ip) else { throw DisplayError("Introduce una dirección IPv4 de tu red local.") }
            let parameters = try Pairing.parameters(code: code.stringValue)
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: 7777, using: parameters)
            let peer = PacketChannel(connection)
            channel = peer; authorized = false; receivedFirstFrame = false
            receivedFrames = 0; acknowledgedFrames = 0; lastDiagnosticMetrics = 0
            playback.reset(); video.reset()
            connectButton.isEnabled = false; host.isEnabled = false; code.isEnabled = false
            peer.onReady = { [weak self, weak peer] in
                self?.status.stringValue = "Conexión cifrada establecida. Acepta la solicitud en la MacBook."
                Diagnostics.shared.event("hello_sent")
                peer?.send(Wire.hello)
            }
            peer.onPacket = { [weak self] data in self?.receive(data) }
            peer.onClose = { [weak self] reason in self?.finish(reason) }
            status.stringValue = "Conectando…"
            peer.start()
        } catch {
            Diagnostics.shared.failure("connect_failed", error: error)
            status.stringValue = error.localizedDescription
        }
    }
    private func receive(_ data: Data) {
        guard let channel else { return }
        if data == Wire.accepted, !authorized {
            authorized = true
            Diagnostics.shared.event("acceptance_received")
            status.stringValue = "Aceptado. Esperando imagen de la MacBook…"
            videoWindow.makeKeyAndOrderFront(nil)
        } else if data == Data([5]), authorized {
            channel.armTimeout(seconds: 10); channel.send(Data([6]))
        } else if data.first == 3, authorized {
            do {
                receivedFrames += 1
                if receivedFrames == 1 { Diagnostics.shared.event("first_video_received") }
                try playback.receive(VideoPacket(data: data))
            } catch {
                Diagnostics.shared.failure("video_packet_failed", error: error)
                channel.close(error.localizedDescription, cause: "video_packet_error")
            }
        } else { channel.close("El emisor envió un mensaje inesperado.", cause: "unexpected_sender_message") }
    }
    private func finish(_ message: String) {
        Diagnostics.shared.event("session_stop", ["authorized": .flag(authorized), "received_frames": .count(receivedFrames), "enqueued_frames": .count(acknowledgedFrames)])
        activity.stop()
        channel = nil; authorized = false; receivedFirstFrame = false
        playback.reset(); video.reset(); videoWindow.orderOut(nil)
        status.stringValue = message
        connectButton.isEnabled = true; host.isEnabled = true; code.isEnabled = true
        controls.makeKeyAndOrderFront(nil)
        updates.sessionEnded()
    }
    @objc private func disconnect() { channel?.close("Desconectado. Prepara una nueva sesión en la MacBook para volver a conectar.", cause: "user_disconnect") }
    @objc private func fullscreen() {
        guard authorized else { status.stringValue = "Conecta primero la MacBook."; return }
        videoWindow.makeKeyAndOrderFront(nil); videoWindow.toggleFullScreen(nil)
    }
    @objc private func sleeping() { channel?.close("Conexión cerrada por reposo. Vuelve a conectar al despertar.", cause: "system_sleep") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === videoWindow { disconnect(); return false }
        NSApp.terminate(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.event("app_terminate")
        activity.stop(); channel?.onClose = nil; channel?.close()
        _ = try? Diagnostics.shared.report()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ReceiverApp() }
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
