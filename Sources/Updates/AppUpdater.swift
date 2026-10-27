import AppKit
import Sparkle

/// Sparkle gestiona firmas, descarga, sustitución y relanzamiento. Las sesiones
/// de pantalla y actualización no comienzan una encima de la otra.
@MainActor final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController!
    private let isConnected: () -> Bool
    private var postponedInstall: (() -> Void)?
    private var installing = false
    private var observation: NSKeyValueObservation?
    let controls = NSStackView()
    private let automatic = NSButton(checkboxWithTitle: "Buscar versiones automáticamente", target: nil, action: nil)

    init(isConnected: @escaping () -> Bool) {
        self.isConnected = isConnected
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        controls.addArrangedSubview(button("Buscar actualizaciones…", target: self, action: #selector(check)))
        controls.addArrangedSubview(automatic)
        controls.spacing = 12
        if let menu = NSApp.mainMenu?.items.first?.submenu {
            let item = NSMenuItem(title: "Buscar actualizaciones…", action: #selector(check), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        observation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshPreference() }
        }
        controller.startUpdater()
    }

    private func refreshPreference() { automatic.state = controller.updater.automaticallyChecksForUpdates ? .on : .off }
    @objc private func changeAutomatic() { controller.updater.automaticallyChecksForUpdates = automatic.state == .on }
    @objc private func check() {
        guard !isConnected() else {
            explain("Desconecta la pantalla antes de buscar actualizaciones.")
            return
        }
        if controller.updater.canCheckForUpdates { controller.checkForUpdates(nil) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller.updater.canCheckForUpdates }

    func mayConnect() -> Bool {
        guard !controller.updater.sessionInProgress, !installing, postponedInstall == nil else {
            explain("Termina o pospón la actualización antes de conectar la pantalla.")
            return false
        }
        return true
    }
    func sessionEnded() {
        guard !isConnected(), let resume = postponedInstall else { return }
        postponedInstall = nil
        resume()
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isConnected() {
            throw NSError(domain: "iMacDisplay.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "La actualización esperará a que desconectes la pantalla."])
        }
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installing = true }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isConnected() else { return false }
        postponedInstall = installHandler
        return true
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { installing = false; postponedInstall = nil }
    }
    private func explain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Actualizaciones"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        alert.runModal()
    }
}
