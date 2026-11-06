import AppKit
import Network

@MainActor final class ReceiverApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var controls: NSWindow!, videoWindow: NSWindow!
    private var updates: AppUpdater!
    private var diagnostics: DiagnosticControls!
    private var receivedFrames = 0, acknowledgedFrames = 0
    private var lastDiagnosticMetrics = 0.0
    private let senders = NSPopUpButton()
    private let browser = SenderBrowser()
    private let host = NSTextField(string: "")
    private let code = NSSecureTextField(string: "")
    private let autoFullScreen = NSButton(checkboxWithTitle: "Pantalla completa al recibir la imagen", target: nil, action: nil)
    private let status = label("Pega la clave que muestra la MacBook. Con el cable USB conectado, la MacBook aparece sola.")
    private let metrics = label("", size: 12)
    private let video = VideoView(frame: .zero)
    private let playback = FrameReceiver()
    private let activity = StreamActivity()
    private var statistics = DecodeStatistics(now: 0)
    private var metricsTimer: Timer?
    private var connectButton: NSButton!
    private var channel: PacketChannel?
    private var authorized = false, receivedFirstFrame = false
    private var userChoseManual = false, hideAfterFullScreen = false
    private var helloSentAt: Double?
    private static let manualTag = "manual"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.configure(role: "Receiver")
        configureMenu()
        updates = AppUpdater(isConnected: { [weak self] in self?.channel != nil })
        controls = makeWindow("iMac Receiver · v\(appVersion) (\(appBuild))", width: 660, height: 600)
        controls.delegate = self
        diagnostics = DiagnosticControls(role: "Receiver", window: controls)
        videoWindow = makeWindow("Pantalla de la MacBook · ⌃⌘F para pantalla completa", width: 1100, height: 650)
        videoWindow.delegate = self; videoWindow.contentView = video
        videoWindow.collectionBehavior = [.fullScreenPrimary]
        video.onShown = { [weak self] milliseconds in
            self?.statistics.shown(at: ProcessInfo.processInfo.systemUptime, decodeMS: milliseconds)
        }
        playback.render = { [weak self] packet, completion in self?.video.display(packet, completion: completion) }
        playback.onAcknowledged = { [weak self] sequence in
            guard let self else { return }
            self.channel?.send(Wire.ack(sequence))
            self.acknowledgedFrames += 1
            if !self.receivedFirstFrame { self.firstFrameShown() }
        }
        playback.onError = { [weak self] message in self?.channel?.close(message, cause: "playback_error") }
        senders.autoenablesItems = false
        senders.target = self; senders.action = #selector(senderChosen)
        host.placeholderString = "Solo si no aparece arriba. Ejemplo: 169.254.10.20 o 192.168.1.10"
        code.placeholderString = "Pega la clave temporal completa"
        autoFullScreen.state = .on
        connectButton = button("Conectar", target: self, action: #selector(connect))
        let actions = NSStackView(views: [connectButton,
            button("Desconectar", target: self, action: #selector(disconnect)),
            button("Pantalla completa", target: self, action: #selector(fullscreen))])
        let stack = NSStackView(views: [label("La pantalla de tu MacBook", size: 25, bold: true),
            label("MacBook", bold: true), senders,
            label("IP manual · puerto 7777", bold: true), host,
            label("Clave de emparejamiento", bold: true), code, actions, autoFullScreen, status, metrics,
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
        browser.onChange = { [weak self] in self?.refreshSenders() }
        browser.start()
        refreshSenders()
        controls.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Descubrimiento

    private func key(_ found: SenderBrowser.Found) -> String {
        "\(found.link.tag)|\(found.interface?.name ?? "-")|\(found.endpoint.debugDescription)"
    }
    private func refreshSenders() {
        // No rehace el menú mientras está abierto: reintenta al cerrarse.
        guard RunLoop.current.currentMode != .eventTracking else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshSenders()
            }
            return
        }
        let previous = senders.selectedItem?.representedObject as? String
        senders.removeAllItems()
        for found in browser.found {
            let item = NSMenuItem(title: found.title, action: nil, keyEquivalent: "")
            item.representedObject = key(found)
            senders.menu?.addItem(item)
        }
        if browser.found.isEmpty {
            let searching = NSMenuItem(title: "Buscando la MacBook… (prepara la conexión en el emisor)", action: nil, keyEquivalent: "")
            searching.isEnabled = false
            senders.menu?.addItem(searching)
        }
        let manual = NSMenuItem(title: "Escribir la IP manualmente", action: nil, keyEquivalent: "")
        manual.representedObject = Self.manualTag
        senders.menu?.addItem(manual)
        // Conserva la elección del usuario; si no, el mejor enlace (cable primero).
        // Un «manual» elegido automáticamente por falta de resultados no se conserva.
        if userChoseManual || browser.found.isEmpty {
            senders.select(manual)
        } else if let previous, previous != Self.manualTag,
                  let index = senders.itemArray.firstIndex(where: { ($0.representedObject as? String) == previous }) {
            senders.selectItem(at: index)
        } else {
            senders.selectItem(at: 0)
        }
        updateHostField()
    }
    @objc private func senderChosen() {
        userChoseManual = (senders.selectedItem?.representedObject as? String) == Self.manualTag
        updateHostField()
    }
    private func updateHostField() {
        host.isEnabled = channel == nil && selectedSender == nil
    }
    private var selectedSender: SenderBrowser.Found? {
        guard let tag = senders.selectedItem?.representedObject as? String, tag != Self.manualTag else { return nil }
        return browser.found.first { key($0) == tag }
    }

    // MARK: - Sesión

    @objc private func connect() {
        guard updates.mayConnect() else { return }
        guard channel == nil else { return }
        Diagnostics.shared.beginSession()
        Diagnostics.shared.event("connect_requested")
        do {
            let parameters = try Pairing.parameters(code: code.stringValue)
            let connection: NWConnection
            if let found = selectedSender {
                if let interface = found.interface { parameters.requiredInterface = interface }
                connection = NWConnection(to: found.endpoint, using: parameters)
                Diagnostics.shared.event("connect_discovered", ["link": .tag(found.link.diagnosticTag),
                    "local_kind": .tag(found.interface.map { LinkInventory.kind(ofInterfaceNamed: $0.name).diagnosticTag } ?? "other")])
            } else {
                let ip = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isLocalIPv4(ip) else {
                    throw DisplayError(browser.found.isEmpty
                        ? "No se encontró la MacBook. Pulsa Preparar conexión en el emisor o escribe su IP local."
                        : "Introduce una dirección IPv4 de tu red local o elige la MacBook de la lista.")
                }
                connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: Discovery.port)!, using: parameters)
                Diagnostics.shared.event("connect_manual")
            }
            let peer = PacketChannel(connection)
            channel = peer; authorized = false; receivedFirstFrame = false; hideAfterFullScreen = false
            receivedFrames = 0; acknowledgedFrames = 0; lastDiagnosticMetrics = 0
            playback.reset(); video.reset()
            statistics = DecodeStatistics(now: ProcessInfo.processInfo.systemUptime)
            connectButton.isEnabled = false; host.isEnabled = false; code.isEnabled = false; senders.isEnabled = false
            peer.onReady = { [weak self, weak peer] in
                self?.status.stringValue = "Conexión cifrada establecida. Acepta la solicitud en la MacBook."
                Diagnostics.shared.event("hello_sent", ["protocol": .count(3)])
                self?.helloSentAt = ProcessInfo.processInfo.systemUptime
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
            metricsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reportMetrics() }
            }
            RunLoop.main.add(metricsTimer!, forMode: .common)
        } else if data == Wire.heartbeat, authorized {
            channel.armTimeout(seconds: 10); channel.send(Wire.heartbeatReply)
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
    private func firstFrameShown() {
        Diagnostics.shared.event("first_video_shown", ["compressed_fallback": .flag(video.compressedFallback),
            "hardware_known": .flag(video.hardwareDecoding != nil), "hardware": .flag(video.hardwareDecoding == true)])
        receivedFirstFrame = true
        activity.start(keepingDisplayAwake: true)
        status.stringValue = "Recibiendo pantalla. Esc sale de pantalla completa."
        if autoFullScreen.state == .on, !videoWindow.styleMask.contains(.fullScreen) {
            videoWindow.makeKeyAndOrderFront(nil); videoWindow.toggleFullScreen(nil)
        }
    }
    /// Una vez por segundo: métricas locales y, con protocolo v3, reporte a la MacBook.
    private func reportMetrics() {
        guard let channel, authorized, receivedFirstFrame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let sample = statistics.snapshot(at: now)
        let report = ReceiverReport(shownFPS: sample.fps, decodeMS: sample.decodeMS,
                                    hardware: video.hardwareDecoding, compressedFallback: video.compressedFallback)
        channel.send(report.serialized())
        let decoder: String
        if video.compressedFallback { decoder = "AVFoundation" }
        else if video.hardwareDecoding == true { decoder = "hardware" }
        else if video.hardwareDecoding == false { decoder = "software (CPU)" }
        else { decoder = "sin confirmar" }
        let decode = sample.decodeMS.map { String(format: " · %.1f ms", $0) } ?? ""
        metrics.stringValue = String(format: "Mostrando %.1f FPS · decodificación %@%@", sample.fps, decoder, decode)
        if videoWindow.styleMask.contains(.fullScreen), videoWindow.isKeyWindow { NSCursor.setHiddenUntilMouseMoves(true) }
        if now - lastDiagnosticMetrics >= 5 {
            lastDiagnosticMetrics = now
            var fields: [String: DiagnosticValue] = ["received_frames": .count(receivedFrames), "shown_frames": .count(acknowledgedFrames),
                "queue": .count(playback.count), "shown_fps": .measure(sample.fps), "compressed_fallback": .flag(video.compressedFallback)]
            if let value = sample.decodeMS { fields["decode_ms"] = .measure(value) }
            if let hardware = video.hardwareDecoding { fields["hardware_decode"] = .flag(hardware) }
            Diagnostics.shared.event("receiver_metrics", fields)
        }
    }
    private func finish(_ message: String) {
        Diagnostics.shared.event("session_stop", ["authorized": .flag(authorized), "received_frames": .count(receivedFrames), "enqueued_frames": .count(acknowledgedFrames)])
        activity.stop()
        metricsTimer?.invalidate(); metricsTimer = nil
        // Un emisor anterior a v0.4 rechaza el saludo v3 y cierra en el acto.
        let rejectedHello = !authorized && helloSentAt.map { ProcessInfo.processInfo.systemUptime - $0 < 1.5 } == true
        if rejectedHello { Diagnostics.shared.event("hello_closed_immediately") }
        helloSentAt = nil
        channel = nil; authorized = false; receivedFirstFrame = false
        playback.reset(); video.reset()
        // Sale primero de pantalla completa; la ventana se oculta al terminar la animación.
        if videoWindow.styleMask.contains(.fullScreen) {
            hideAfterFullScreen = true
            videoWindow.toggleFullScreen(nil)
        } else { videoWindow.orderOut(nil) }
        status.stringValue = rejectedHello
            ? "La MacBook cerró la conexión al recibir el saludo. Si usa una versión anterior a v0.4, actualiza iMac Sender."
            : message
        metrics.stringValue = ""
        connectButton.isEnabled = true; code.isEnabled = true; senders.isEnabled = true
        updateHostField()
        controls.makeKeyAndOrderFront(nil)
        updates.sessionEnded()
    }
    @objc private func disconnect() { channel?.close("Desconectado. Prepara una nueva sesión en la MacBook para volver a conectar.", cause: "user_disconnect") }
    @objc private func fullscreen() {
        guard authorized else { status.stringValue = "Conecta primero la MacBook."; return }
        videoWindow.makeKeyAndOrderFront(nil); videoWindow.toggleFullScreen(nil)
    }
    @objc private func sleeping() { channel?.close("Conexión cerrada por reposo. Vuelve a conectar al despertar.", cause: "system_sleep") }
    func windowDidEnterFullScreen(_ notification: Notification) {
        if (notification.object as? NSWindow) === videoWindow { NSCursor.setHiddenUntilMouseMoves(true) }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === videoWindow, hideAfterFullScreen, channel == nil else { return }
        hideAfterFullScreen = false
        videoWindow.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === videoWindow { disconnect(); return false }
        NSApp.terminate(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.event("app_terminate")
        browser.stop(); metricsTimer?.invalidate()
        activity.stop(); channel?.onClose = nil; channel?.close()
        _ = try? Diagnostics.shared.report()
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { ReceiverApp() }
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
