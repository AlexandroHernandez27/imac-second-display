import AppKit

@MainActor final class DisplayManager {
    private var process: Process?
    private var input: Pipe?
    private(set) var id: CGDirectDisplayID = 0
    var onUnexpectedExit: (() -> Void)?

    func start(width: Int, height: Int, fps: Int) async throws {
        guard process == nil else { throw DisplayError("Ya existe una pantalla virtual.") }
        let task = Process()
        task.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DisplayHelper")
        task.arguments = [String(width), String(height), String(fps)]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        try task.run()
        process = task; input = stdin
        // availableData se ejecuta fuera del hilo de interfaz y tiene un watchdog.
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: stdout.fileHandleForReading.availableData) }
        }
        watchdog.cancel()
        guard process === task else { throw CancellationError() }
        guard let value = UInt32(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), value != 0 else {
            stop()
            throw DisplayError("No se pudo crear la pantalla virtual. La API privada puede haber cambiado.")
        }
        id = value
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { if self?.process === task { self?.onUnexpectedExit?() } }
        }
        do {
            for _ in 0..<40 {
                if CGDisplayIsOnline(id) != 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard CGDisplayIsOnline(id) != 0 else { throw DisplayError("La pantalla virtual no apareció.") }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw DisplayError("No se pudo configurar la pantalla.") }
            let right = NSScreen.screens.filter { screenID($0) != id }.map { CGDisplayBounds(screenID($0)).maxX }.max() ?? 0
            let origin = CGConfigureDisplayOrigin(config, id, Int32(right), 0)
            guard origin == .success else { CGCancelDisplayConfiguration(config); throw DisplayError("No se pudo extender el escritorio.") }
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw DisplayError("macOS rechazó la disposición de pantallas.") }
            for _ in 0..<40 {
                if NSScreen.screens.contains(where: { screenID($0) == id }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard CGDisplayIsInMirrorSet(id) == 0, CGDisplayMirrorsDisplay(id) == 0,
                  CGDisplayIsActive(id) != 0, id != CGMainDisplayID() else { throw DisplayError("La pantalla no quedó como escritorio independiente.") }
        } catch { stop(); throw error }
    }
    func stop() {
        let task = process
        process = nil; id = 0
        try? input?.fileHandleForWriting.close(); input = nil
        // EOF termina el helper; SIGTERM es respaldo si su run loop deja de responder.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if task?.isRunning == true { task?.terminate() } }
    }
}
func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}
