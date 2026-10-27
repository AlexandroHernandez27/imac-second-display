import AppKit

final class MotionPatternView: NSView {
    private let started = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 25, weight: .medium), .foregroundColor: NSColor.labelColor]
        let text = String(format: "Pantalla independiente · prueba de movimiento\n\nTiempo: %07.2f s\n\nAa Bb Cc · 0123456789\nEl indicador debe avanzar sin quedarse atrás.\n\nRevisa los FPS de los últimos 2 segundos.\nCierra esta ventana para volver al escritorio.", elapsed)
        (text as NSString).draw(in: NSRect(x: 32, y: 120, width: bounds.width - 64, height: bounds.height - 150), withAttributes: style)
        let travel = max(1, bounds.width - 104)
        let progress = (sin(elapsed * 2) + 1) / 2
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32 + travel * progress, y: 40, width: 40, height: 40), xRadius: 8, yRadius: 8).fill()
    }
    deinit { timer?.invalidate() }
}
