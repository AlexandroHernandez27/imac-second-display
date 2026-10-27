import Foundation

/// Actividad limitada a la sesión; nunca cambia preferencias globales de energía.
final class StreamActivity {
    private var token: NSObjectProtocol?

    func start(keepingDisplayAwake: Bool) {
        guard token == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]
        if keepingDisplayAwake { options.insert(.idleDisplaySleepDisabled) }
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: "Pantalla extendida por red en uso")
    }

    func stop() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit { stop() }
}
