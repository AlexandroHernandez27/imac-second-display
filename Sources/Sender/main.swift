import AppKit
import Network

@MainActor final class SenderApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct Resolution { let title: String; let width: Int; let height: Int }
    private let resolutions = [Resolution(title: "2560 × 1440 · nativa de la iMac 27\"", width: 2560, height: 1440),
                               Resolution(title: "1920 × 1080", width: 1920, height: 1080),
                               Resolution(title: "1280 × 720", width: 1280, height: 720)]
    private let rates = [60, 30, 15]
    private let bitrates = [6, 12, 20, 40, 80] // Mbps
    private var window: NSWindow!
    private var updates: AppUpdater!
    private var diagnostics: DiagnosticControls!
    private var lastDiagnosticMetrics = 0.0, lastDiagnosticReport = 0.0
    private let links = NSPopUpButton()
    private let linkHint = label("", size: 12)
    private let resolution = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let quality = NSPopUpButton()
    private let code = NSTextField(string: "")
    private let status = label("Prepara la conexión y abre el receptor en la iMac.")
    private let metrics = label("", size: 12)
    private var startButton: NSButton!, stopButton: NSButton!
    private var availableLinks: [LocalLink] = []
    private var pickedLink: String?          // elección explícita; si no, el mejor enlace
    private var presetLink: String?          // evita pisar ajustes manuales
    private var linkTimer: Timer?
    private var listeners: [NWListener] = []
    private var readyListeners = 0, failedListeners = 0
    private let advertiser = BonjourAdvertiser()
    private var sessionLink: LocalLink?
    private var channel: PacketChannel?
    private var display = DisplayManager()
    private var capture: CapturePipeline?
    private let activity = StreamActivity()
    private var startTask: Task<Void, Never>?
    private var pattern: NSWindow?
    private var heartbeat: Timer?
    private var metricsTimer: Timer?
    private var peer = Wire.Peer(window: 3, version: 2)
    private var report: (value: ReceiverReport, time: Double)?
    private var streaming = false, stopping = false, receivedHello = false
    private var generation = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.configure(role: "Sender")
        configureMenu()
        updates = AppUpdater(isConnected: { [weak self] in self?.listeners.isEmpty == false || self?.stopping == true })
        window = makeWindow("iMac Sender · v\(appVersion) (\(appBuild)) · MacBook", width: 700, height: 760)
        window.delegate = self
        diagnostics = DiagnosticControls(role: "Sender", window: window)
        links.autoenablesItems = false
        links.target = self; links.action = #selector(linkChosen)
        resolution.addItems(withTitles: resolutions.map(\.title))
        fps.addItems(withTitles: rates.map { "\($0) FPS" })
        quality.addItems(withTitles: bitrates.map { "\($0) Mbps" })
        code.isEditable = false; code.isSelectable = true
        code.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        startButton = button("Preparar conexión", target: self, action: #selector(prepare))
        stopButton = button("Desconectar", target: self, action: #selector(disconnect))
        stopButton.isEnabled = false
        let actions = NSStackView(views: [startButton, stopButton, button("Copiar clave", target: self, action: #selector(copyCode))])
        let modes = NSStackView(views: [resolution, fps, quality])
        let stack = NSStackView(views: [
            label("Tu iMac, como segunda pantalla", size: 25, bold: true),
            label("Las aplicaciones corren en esta MacBook. La iMac recibe la imagen por cable USB o por la red local."),
            label("1. Conexión con la iMac · puerto 7777", bold: true), links, linkHint,
            label("2. Resolución, fluidez y calidad", bold: true), modes,
            label("3. Clave temporal para pegar en el receptor", bold: true), code, actions,
            status, metrics,
            button("Prueba de movimiento", target: self, action: #selector(showPattern)),
            label("Mueve ventanas por el borde derecho de la MacBook. Puedes cambiar la posición en Ajustes del Sistema → Pantallas.", size: 12),
            updates.controls,
            diagnostics.makeButton(),
            label("v\(appVersion) · experimental · las actualizaciones requieren tu confirmación", size: 11)
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            code.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        display.onUnexpectedExit = { [weak self] in self?.stopSession("La pantalla virtual terminó inesperadamente.", cause: "display_helper_exit") }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refreshLinks()
        // El cable se puede conectar con la app abierta; también vigila la sesión.
        linkTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLinks() }
        }
        RunLoop.main.add(linkTimer!, forMode: .common)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Enlaces

    private var selectedLink: LocalLink? {
        guard let name = links.selectedItem?.representedObject as? String else { return nil }
        return availableLinks.first { $0.name == name }
    }
    private func refreshLinks() {
        let current = LinkInventory.current()
        if !listeners.isEmpty || stopping {
            // Durante la sesión solo se comprueba que el enlace elegido siga vivo.
            if let link = sessionLink, !stopping, !current.contains(where: { $0.name == link.name }) {
                Diagnostics.shared.event("session_link_lost", ["kind": .tag(link.kind.diagnosticTag)])
                stopSession(link.kind == .usbCable
                    ? "Se desconectó el cable USB. Vuelve a conectarlo y prepara una nueva conexión."
                    : "Se perdió la conexión \(link.kind.title). Vuelve a conectar y prepara una nueva conexión.", cause: "link_lost")
            }
            return
        }
        guard current != availableLinks || links.numberOfItems == 0 else { return }
        // No rehace el menú mientras está abierto; el siguiente ciclo lo actualiza.
        guard RunLoop.current.currentMode != .eventTracking else { return }
        let hadUSB = availableLinks.contains { $0.kind == .usbCable }
        availableLinks = current
        links.removeAllItems()
        if current.isEmpty {
            links.addItem(withTitle: "Sin red local: conecta el cable USB o Wi‑Fi")
            links.lastItem?.isEnabled = false
        }
        for link in current {
            let item = NSMenuItem(title: link.menuTitle, action: nil, keyEquivalent: "")
            item.representedObject = link.name
            links.menu?.addItem(item)
        }
        let chosen = current.firstIndex { $0.name == pickedLink } ?? 0
        if !current.isEmpty { links.selectItem(at: chosen) }
        if let link = selectedLink { applyPreset(for: link) }
        if current.contains(where: { $0.kind == .usbCable }) != hadUSB {
            Diagnostics.shared.event("usb_cable_changed", ["present": .flag(!hadUSB)])
        }
        updateLinkHint()
    }
    @objc private func linkChosen() {
        pickedLink = links.selectedItem?.representedObject as? String
        if let link = selectedLink { applyPreset(for: link) }
        updateLinkHint()
    }
    /// Valores recomendados al cambiar de enlace; luego se respetan los cambios manuales.
    private func applyPreset(for link: LocalLink) {
        guard presetLink != link.name else { return }
        presetLink = link.name
        let (width, rate, mbps) = link.kind.isWired ? (2560, 60, 40) : (1920, 30, 12)
        resolution.selectItem(at: resolutions.firstIndex { $0.width == width } ?? 0)
        fps.selectItem(at: rates.firstIndex(of: rate) ?? 0)
        quality.selectItem(at: bitrates.firstIndex(of: mbps) ?? 0)
    }
    private func updateLinkHint() {
        guard let link = selectedLink else {
            linkHint.stringValue = "Para máxima fluidez conecta un cable USB‑A (iMac) → USB‑C (MacBook). No hace falta adaptador."
            return
        }
        switch link.kind {
        case .usbCable:
            let speed = (link.speedMbps ?? 0) >= 5000
                ? "USB 3: margen de sobra para 1440p a 60 FPS."
                : "USB 2.0 (≈340 Mbps medidos): suficiente para 1440p a 60 FPS. Un cable USB 3 da más margen."
            let address = link.ipv4 == nil ? " La IPv4 tarda unos 20 s; la iMac puede encontrar la MacBook antes." : ""
            linkHint.stringValue = "Cable directo a la iMac. \(speed)\(address)"
        case .thunderbolt, .ethernet:
            linkHint.stringValue = "Conexión por cable: se recomienda 2560 × 1440 a 60 FPS."
        case .wifi, .other:
            let usb = availableLinks.contains { $0.kind == .usbCable } ? "" : " Con un cable USB‑A → USB‑C la imagen será más estable."
            linkHint.stringValue = "Wi‑Fi puede variar con la señal.\(usb)"
        }
    }

    // MARK: - Sesión

    @objc private func prepare() {
        guard updates.mayConnect() else { return }
        guard listeners.isEmpty, !stopping else { return }
        Diagnostics.shared.beginSession()
        Diagnostics.shared.event("listener_requested")
        do {
            refreshLinks()
            guard let link = selectedLink, !link.bindHosts.isEmpty else {
                throw DisplayError("No hay conexión con la iMac. Conecta el cable USB‑A → USB‑C o une ambas Macs al mismo Wi‑Fi.")
            }
            let secret = try Pairing.generate()
            generation = UUID(); receivedHello = false
            let epoch = generation
            var created = [NWListener]()
            // IPv6 link-local sirve al instante en el cable; IPv4 permite escribir la IP.
            for host in link.bindHosts {
                let parameters = try Pairing.parameters(code: secret)
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Discovery.port)!)
                let server = try NWListener(using: parameters)
                server.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated { self?.listenerChanged(state, epoch: epoch) }
                }
                server.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == epoch, !self.stopping else { connection.cancel(); return }
                        self.accept(connection)
                    }
                }
                created.append(server)
            }
            listeners = created; readyListeners = 0; failedListeners = 0
            sessionLink = link; report = nil
            code.stringValue = secret
            for server in created { server.start(queue: .main) }
            advertiser.onUpdate = { error in
                Diagnostics.shared.event("bonjour_registration", ["status": .count(Int(error))])
            }
            let advertised = advertiser.start(interfaceIndex: link.interfaceIndex, link: link.kind)
            Diagnostics.shared.event("listener_link", ["kind": .tag(link.kind.diagnosticTag), "ipv4": .flag(link.ipv4 != nil),
                "ipv6_link_local": .flag(link.ipv6LinkLocal != nil), "speed_mbps": .count(link.speedMbps ?? 0),
                "bonjour_status": .count(Int(advertised))])
            setOptions(enabled: false)
            stopButton.isEnabled = true
            let manual = link.ipv4.map { " Si no aparece, escribe la IP \($0)." } ?? ""
            status.stringValue = "Esperando a la iMac por \(link.kind.title). Abre iMac Receiver: la MacBook aparecerá en la lista; pega esta clave.\(manual)"
            metrics.stringValue = "Todavía no se transmite el escritorio."
        } catch {
            Diagnostics.shared.failure("prepare_failed", error: error)
            stopListeners()
            status.stringValue = error.localizedDescription
        }
    }
    private func listenerChanged(_ state: NWListener.State, epoch: UUID) {
        guard generation == epoch, !stopping else { return }
        switch state {
        case .ready:
            readyListeners += 1
            if readyListeners == 1 { Diagnostics.shared.event("listener_ready") }
        case .failed(let error):
            failedListeners += 1
            Diagnostics.shared.failure("listener_failed", error: error)
            // Basta con una dirección: la IPv6 puede estar en verificación al conectar el cable.
            if failedListeners >= listeners.count {
                stopSession("No se pudo escuchar en la red: \(error.localizedDescription)", cause: "listener_failed")
            }
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        guard channel == nil, !stopping else {
            Diagnostics.shared.event("extra_connection_rejected")
            connection.cancel(); return
        }
        Diagnostics.shared.event("peer_connected")
        advertiser.stop() // Un solo receptor por sesión.
        let peerChannel = PacketChannel(connection)
        channel = peerChannel
        peerChannel.onPacket = { [weak self] data in self?.packet(data) }
        peerChannel.onClose = { [weak self] reason in self?.stopSession(reason, cause: "transport_closed") }
        peerChannel.start()
    }
    private func packet(_ data: Data) {
        guard let channel, !stopping else { return }
        if !receivedHello {
            guard let negotiated = Wire.peer(forHello: data) else {
                Diagnostics.shared.event("hello_incompatible", ["bytes": .count(data.count)])
                channel.close("Protocolo incompatible. Cierra las copias antiguas y abre la versión actual en ambas Macs.", cause: "invalid_hello"); return
            }
            peer = negotiated
            receivedHello = true
            Diagnostics.shared.event("hello_received", ["frame_window": .count(peer.window), "protocol": .count(peer.version)])
            Diagnostics.shared.event("consent_requested")
            let epoch = generation
            let alert = NSAlert()
            alert.messageText = "¿Transmitir a esta iMac?"
            alert.informativeText = "Un receptor con la clave de esta sesión solicita la pantalla adicional. Acepta si acabas de conectarlo desde tu iMac."
            alert.addButton(withTitle: "Aceptar y transmitir"); alert.addButton(withTitle: "Rechazar")
            alert.beginSheetModal(for: window) { [weak self] answer in
                guard let self, self.generation == epoch, !self.stopping else { return }
                if answer == .alertFirstButtonReturn {
                    Diagnostics.shared.event("consent_accepted")
                    self.beginStreaming()
                } else { self.stopSession("Conexión rechazada.", cause: "consent_rejected") }
            }
        } else if data.first == 4, data.count == 5, streaming {
            guard let sequence = try? data.uint32(at: 1) else { channel.close("Confirmación inválida."); return }
            capture?.acknowledge(sequence)
        } else if data == Wire.heartbeatReply, streaming {
            channel.armTimeout(seconds: 10)
        } else if data.first == ReceiverReport.type, peer.version >= 3, streaming {
            guard let value = ReceiverReport(data: data) else { channel.close("Métricas del receptor inválidas.", cause: "invalid_report"); return }
            report = (value, ProcessInfo.processInfo.systemUptime)
            logReport(value)
        } else { channel.close("Mensaje inesperado del receptor.", cause: "unexpected_receiver_message") }
    }
    private func logReport(_ value: ReceiverReport) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnosticReport >= 5 else { return }
        lastDiagnosticReport = now
        var fields: [String: DiagnosticValue] = ["shown_fps": .measure(value.shownFPS), "compressed_fallback": .flag(value.compressedFallback)]
        if let hardware = value.hardware { fields["hardware_decode"] = .flag(hardware) }
        if let decode = value.decodeMS { fields["decode_ms"] = .measure(decode) }
        Diagnostics.shared.event("receiver_report", fields)
    }
    private func beginStreaming() {
        let epoch = generation
        let mode = resolutions[max(0, resolution.indexOfSelectedItem)]
        let (width, height) = (mode.width, mode.height)
        let rate = rates[max(0, fps.indexOfSelectedItem)]
        let bitrate = bitrates[max(0, quality.indexOfSelectedItem)] * 1_000_000
        Diagnostics.shared.event("stream_start_requested", ["width": .count(width), "height": .count(height), "fps": .count(rate), "bitrate": .count(bitrate),
            "link": .tag(sessionLink?.kind.diagnosticTag ?? "other")])
        status.stringValue = "Preparando pantalla y permiso de grabación de pantalla…"
        startTask = Task { @MainActor in
            do {
                try await display.start(width: width, height: height, fps: rate)
                try Task.checkCancellation()
                guard generation == epoch else { return }
                let preflight = CGPreflightScreenCaptureAccess()
                Diagnostics.shared.event("capture_permission_preflight", ["granted": .flag(preflight)])
                let permitted = preflight || CGRequestScreenCaptureAccess()
                Diagnostics.shared.event("capture_permission_result", ["granted": .flag(permitted)])
                guard permitted else {
                    throw DisplayError("Activa iMac Sender en Ajustes → Privacidad y seguridad → Grabación de pantalla; después cierra y abre la app.")
                }
                let pipeline = CapturePipeline(window: peer.window)
                capture = pipeline
                pipeline.onFrame = { [weak self] data, sequence in
                    guard let self, self.generation == epoch, self.streaming, !self.stopping else { return }
                    if sequence == 1 { Diagnostics.shared.event("first_video_sent") }
                    self.channel?.send(data)
                }
                pipeline.onError = { [weak self] reason in self?.stopSession(reason, cause: "capture_pipeline_error") }
                // accepted debe preceder al primer fotograma en el flujo TCP.
                channel?.send(Wire.accepted)
                Diagnostics.shared.event("acceptance_sent")
                streaming = true
                activity.start(keepingDisplayAwake: false)
                try await pipeline.start(displayID: display.id, width: width, height: height, fps: rate, bitrate: bitrate)
                try Task.checkCancellation()
                guard generation == epoch else { return }
                Diagnostics.shared.event("stream_running")
                lastDiagnosticMetrics = 0; lastDiagnosticReport = 0
                status.stringValue = "Conectado por \(sessionLink?.kind.title ?? "red local") · \(width) × \(height), hasta \(rate) FPS. Mueve las ventanas hacia la derecha."
                heartbeat = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.channel?.send(Wire.heartbeat) }
                }
                RunLoop.main.add(heartbeat!, forMode: .common)
                metricsTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshMetrics(epoch: epoch, fps: rate) }
                }
                RunLoop.main.add(metricsTimer!, forMode: .common)
            } catch {
                if generation == epoch {
                    Diagnostics.shared.failure("stream_start_failed", error: error)
                    stopSession(error.localizedDescription, cause: "stream_start_failed")
                }
            }
        }
    }
    private func refreshMetrics(epoch: UUID, fps: Int) {
        capture?.metrics { [weak self] sample in
            guard let self, self.generation == epoch, self.streaming else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastDiagnosticMetrics >= 5 || sample.oldestPendingAge > 5 {
                self.lastDiagnosticMetrics = now
                var fields: [String: DiagnosticValue] = ["capture_fps": .measure(sample.capturedFPS), "delivered_fps": .measure(sample.deliveredFPS),
                    "mbps": .measure(sample.megabitsPerSecond), "pending": .count(sample.inFlight), "oldest_pending_s": .measure(sample.oldestPendingAge),
                    "source_idle": .flag(sample.sourceIdle), "refined": .count(sample.refinedFrames)]
                if let value = sample.preparationMS { fields["preparation_ms"] = .measure(value) }
                if let value = sample.ackMS { fields["ack_ms"] = .measure(value) }
                Diagnostics.shared.event("video_metrics", fields)
            }
            if sample.oldestPendingAge > 5 { self.stopSession("El video dejó de avanzar. Vuelve a conectar la iMac.", cause: "video_ack_timeout"); return }
            let preparation = sample.preparationMS.map { String(format: "%.0f", $0) } ?? "—"
            let ack = sample.ackMS.map { String(format: "%.0f", $0) } ?? "—"
            let idle = sample.sourceIdle ? " · sin nuevos fotogramas" : ""
            let refined = sample.refinedFrames > 0 ? " · afinado \(sample.refinedFrames)" : ""
            let legacy = self.peer.window == 1 ? " · actualiza el receptor para mejorar el envío" : ""
            let ackLabel = self.peer.version >= 3 ? "ACK tras decodificar" : "ACK"
            self.metrics.stringValue = String(format: "Últimos 2 s · captura %.1f FPS · entrega %.1f / %d FPS · %.1f Mbps", sample.capturedFPS, sample.deliveredFPS, fps, sample.megabitsPerSecond)
                + "\nH.264 · preparación \(preparation) ms · \(ackLabel) \(ack) ms · pendientes \(sample.inFlight)/\(self.peer.window)\(idle)\(refined)\(legacy)"
                + "\n" + self.receiverLine(now: now)
        }
    }
    private func receiverLine(now: Double) -> String {
        let link = sessionLink.map { [$0.kind.title, $0.speedLabel].compactMap { $0 }.joined(separator: " · ") } ?? "Red local"
        guard peer.version >= 3 else { return "\(link) · actualiza iMac Receiver a v0.4 para ver las métricas de la iMac" }
        guard let report, now - report.time < 3 else { return "\(link) · esperando métricas de la iMac" }
        let value = report.value
        let decoder: String
        if value.compressedFallback { decoder = "decodificación de AVFoundation" }
        else if value.hardware == true { decoder = "decodificación por hardware" }
        else if value.hardware == false { decoder = "decodificación por software (CPU)" }
        else { decoder = "decodificación sin confirmar" }
        let decode = value.decodeMS.map { String(format: " en %.1f ms", $0) } ?? ""
        return String(format: "%@ · iMac muestra %.1f FPS · %@%@", link, value.shownFPS, decoder, decode)
    }
    @objc private func showPattern() {
        guard streaming, let screen = NSScreen.screens.first(where: { screenID($0) == display.id }) else { status.stringValue = "Conecta primero la iMac para mostrar el patrón."; return }
        if let pattern { pattern.orderFrontRegardless(); return }
        let patternWindow = NSWindow(contentRect: NSRect(x: screen.frame.minX + 70, y: screen.frame.minY + 70, width: 900, height: 550),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
        patternWindow.isReleasedWhenClosed = false
        patternWindow.title = "Escritorio extendido · prueba de legibilidad"
        patternWindow.contentView = MotionPatternView(frame: NSRect(x: 0, y: 0, width: 900, height: 550))
        patternWindow.orderFrontRegardless(); pattern = patternWindow
    }
    @objc private func copyCode() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.stringValue, forType: .string) }
    @objc private func disconnect() { stopSession("Desconectado. Prepara una nueva conexión para volver a usar la iMac.", cause: "user_disconnect") }
    @objc private func sleeping() { stopSession("Sesión cerrada por reposo. Vuelve a conectar al despertar.", cause: "system_sleep") }
    @objc private func screenChanged() {
        if streaming && (CGDisplayIsOnline(display.id) == 0 || CGDisplayIsInMirrorSet(display.id) != 0) {
            stopSession("La pantalla virtual cambió o se activó duplicación. Se detuvo la transmisión.", cause: "display_changed")
        }
    }
    private func setOptions(enabled: Bool) {
        startButton.isEnabled = enabled; links.isEnabled = enabled
        resolution.isEnabled = enabled; fps.isEnabled = enabled; quality.isEnabled = enabled
    }
    private func stopListeners() {
        advertiser.stop(); advertiser.onUpdate = nil
        for server in listeners {
            server.stateUpdateHandler = nil; server.newConnectionHandler = nil
            server.cancel()
        }
        listeners = []
    }
    private func stopSession(_ reason: String, cause: StaticString = "session_stop") {
        guard !stopping else { return }
        Diagnostics.shared.event("session_stop", ["cause": .tag(cause), "streaming": .flag(streaming), "received_hello": .flag(receivedHello)])
        stopping = true; generation = UUID(); streaming = false
        activity.stop()
        status.stringValue = reason
        heartbeat?.invalidate(); heartbeat = nil
        metricsTimer?.invalidate(); metricsTimer = nil
        let startup = startTask; startTask = nil; startup?.cancel()
        channel?.onClose = nil; channel?.close(); channel = nil
        stopListeners()
        sessionLink = nil; report = nil
        pattern?.orderOut(nil); pattern = nil
        display.stop(); receivedHello = false
        code.stringValue = ""; stopButton.isEnabled = false
        Task { @MainActor in
            await startup?.value
            await capture?.stop(); capture = nil
            stopping = false; setOptions(enabled: true)
            refreshLinks()
            updates.sessionEnded()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.event("app_terminate")
        activity.stop()
        heartbeat?.invalidate(); metricsTimer?.invalidate(); linkTimer?.invalidate()
        stopListeners()
        channel?.onClose = nil; channel?.close(); display.stop()
        _ = try? Diagnostics.shared.report() // Flush before process exit.
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { SenderApp() }
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
