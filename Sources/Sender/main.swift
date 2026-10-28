import AppKit
import Network

@MainActor final class SenderApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var updates: AppUpdater!
    private var diagnostics: DiagnosticControls!
    private var lastDiagnosticMetrics = 0.0
    private let addresses = NSPopUpButton()
    private let resolution = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let quality = NSPopUpButton()
    private let code = NSTextField(string: "")
    private let status = label("Prepara la conexión y abre el receptor en la iMac.")
    private let metrics = label("", size: 12)
    private var startButton: NSButton!, stopButton: NSButton!
    private var listener: NWListener?
    private var channel: PacketChannel?
    private var display = DisplayManager()
    private var capture: CapturePipeline?
    private let activity = StreamActivity()
    private var startTask: Task<Void, Never>?
    private var pattern: NSWindow?
    private var heartbeat: Timer?
    private var metricsTimer: Timer?
    private var frameWindow = 3
    private var streaming = false, stopping = false, receivedHello = false
    private var generation = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.configure(role: "Sender")
        configureMenu()
        updates = AppUpdater(isConnected: { [weak self] in self?.listener != nil || self?.stopping == true })
        window = makeWindow("iMac Sender · v\(appVersion) (\(appBuild)) · MacBook", width: 680, height: 700)
        window.delegate = self
        diagnostics = DiagnosticControls(role: "Sender", window: window)
        addresses.addItems(withTitles: localAddresses())
        resolution.addItems(withTitles: ["1920 × 1080", "2560 × 1440", "1280 × 720"])
        fps.addItems(withTitles: ["30 FPS", "60 FPS", "15 FPS"])
        quality.addItems(withTitles: ["12 Mbps", "20 Mbps", "6 Mbps"])
        code.isEditable = false; code.isSelectable = true
        code.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        startButton = button("Preparar conexión", target: self, action: #selector(prepare))
        stopButton = button("Desconectar", target: self, action: #selector(disconnect))
        stopButton.isEnabled = false
        let actions = NSStackView(views: [startButton, stopButton, button("Copiar clave", target: self, action: #selector(copyCode))])
        let modes = NSStackView(views: [resolution, fps, quality])
        let stack = NSStackView(views: [
            label("Tu iMac, como segunda pantalla", size: 25, bold: true),
            label("Las aplicaciones corren en esta MacBook. La iMac recibe la imagen por la red local."),
            label("1. Dirección IP de esta MacBook · puerto 7777", bold: true), addresses,
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func prepare() {
        guard updates.mayConnect() else { return }
        guard listener == nil, !stopping else { return }
        Diagnostics.shared.beginSession()
        Diagnostics.shared.event("listener_requested")
        do {
            guard let ip = addresses.titleOfSelectedItem, isLocalIPv4(ip) else { throw DisplayError("No se encontró una IP local. Conecta la MacBook a Wi‑Fi y vuelve a abrir la app.") }
            let secret = try Pairing.generate()
            let parameters = try Pairing.parameters(code: secret)
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: 7777)
            let server = try NWListener(using: parameters)
            listener = server; code.stringValue = secret
            generation = UUID(); receivedHello = false
            let epoch = generation
            server.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.generation == epoch, !self.stopping else { return }
                    if case .ready = state { Diagnostics.shared.event("listener_ready") }
                    if case .failed(let error) = state {
                        Diagnostics.shared.failure("listener_failed", error: error)
                        self.stopSession("No se pudo escuchar en la red: \(error.localizedDescription)", cause: "listener_failed")
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.generation == epoch, !self.stopping else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            server.start(queue: .main)
            setOptions(enabled: false)
            stopButton.isEnabled = true
            status.stringValue = "Esperando a la iMac. Introduce \(ip), puerto 7777 y esta clave en el receptor."
            metrics.stringValue = "Todavía no se transmite el escritorio."
        } catch {
            Diagnostics.shared.failure("prepare_failed", error: error)
            status.stringValue = error.localizedDescription
        }
    }
    private func accept(_ connection: NWConnection) {
        guard channel == nil, !stopping else {
            Diagnostics.shared.event("extra_connection_rejected")
            connection.cancel(); return
        }
        Diagnostics.shared.event("peer_connected")
        let peer = PacketChannel(connection)
        channel = peer
        peer.onPacket = { [weak self] data in self?.packet(data) }
        peer.onClose = { [weak self] reason in self?.stopSession(reason, cause: "transport_closed") }
        peer.start()
    }
    private func packet(_ data: Data) {
        guard let channel, !stopping else { return }
        if !receivedHello {
            guard let capacity = Wire.frameWindow(forHello: data) else {
                Diagnostics.shared.event("hello_incompatible", ["bytes": .count(data.count)])
                channel.close("Protocolo incompatible. Cierra las copias antiguas y abre la versión actual en ambas Macs.", cause: "invalid_hello"); return
            }
            frameWindow = capacity
            receivedHello = true
            Diagnostics.shared.event("hello_received", ["frame_window": .count(frameWindow)])
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
        } else if data == Data([6]), streaming {
            channel.armTimeout(seconds: 10)
        } else { channel.close("Mensaje inesperado del receptor.", cause: "unexpected_receiver_message") }
    }
    private func beginStreaming() {
        let epoch = generation
        let sizes = [(1920, 1080), (2560, 1440), (1280, 720)]
        let (width, height) = sizes[resolution.indexOfSelectedItem]
        let rate = [30, 60, 15][fps.indexOfSelectedItem]
        let bitrate = [12_000_000, 20_000_000, 6_000_000][quality.indexOfSelectedItem]
        Diagnostics.shared.event("stream_start_requested", ["width": .count(width), "height": .count(height), "fps": .count(rate), "bitrate": .count(bitrate)])
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
                let pipeline = CapturePipeline(window: frameWindow)
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
                lastDiagnosticMetrics = 0
                status.stringValue = "Conectado · \(width) × \(height), hasta \(rate) FPS. Mueve las ventanas hacia la derecha."
                heartbeat = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.channel?.send(Data([5])) }
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
                    "source_idle": .flag(sample.sourceIdle)]
                if let value = sample.preparationMS { fields["preparation_ms"] = .measure(value) }
                if let value = sample.ackMS { fields["ack_ms"] = .measure(value) }
                Diagnostics.shared.event("video_metrics", fields)
            }
            if sample.oldestPendingAge > 5 { self.stopSession("El video dejó de avanzar. Vuelve a conectar la iMac.", cause: "video_ack_timeout"); return }
            let preparation = sample.preparationMS.map { String(format: "%.0f", $0) } ?? "—"
            let ack = sample.ackMS.map { String(format: "%.0f", $0) } ?? "—"
            let idle = sample.sourceIdle ? " · sin nuevos fotogramas" : ""
            let legacy = self.frameWindow == 1 ? " · actualiza el receptor para mejorar el envío" : ""
            self.metrics.stringValue = String(format: "Últimos 2 s · captura %.1f FPS · entrega %.1f / %d FPS · %.1f Mbps", sample.capturedFPS, sample.deliveredFPS, fps, sample.megabitsPerSecond)
                + "\nH.264 · preparación \(preparation) ms · ACK \(ack) ms · pendientes \(sample.inFlight)/\(self.frameWindow)\(idle)\(legacy)"
        }
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
        startButton.isEnabled = enabled; addresses.isEnabled = enabled
        resolution.isEnabled = enabled; fps.isEnabled = enabled; quality.isEnabled = enabled
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
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        pattern?.orderOut(nil); pattern = nil
        display.stop(); receivedHello = false
        code.stringValue = ""; stopButton.isEnabled = false
        Task { @MainActor in
            await startup?.value
            await capture?.stop(); capture = nil
            stopping = false; setOptions(enabled: true)
            updates.sessionEnded()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.event("app_terminate")
        activity.stop()
        heartbeat?.invalidate(); metricsTimer?.invalidate(); listener?.cancel()
        channel?.onClose = nil; channel?.close(); display.stop()
        _ = try? Diagnostics.shared.report() // Flush before process exit.
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { SenderApp() }
app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
