import AppKit

func displays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}
func pump(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let before = Set(displays())
if CommandLine.arguments.contains("--list") {
    print(displays().sorted().map(String.init).joined(separator: ","))
    exit(0)
}
let display = ISDVirtualDisplay()
var passed = false
autoreleasepool {
do {
    guard ISDVirtualDisplay.isAvailable() else { throw NSError(domain: "API privada ausente", code: 1) }
    try display.start(width: 1920, height: 1080, refreshRate: 30)
    let id = display.displayID
    pump(1)
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        throw NSError(domain: "No se pudo iniciar la configuración", code: 2)
    }
    let right = displays().filter { $0 != id }.map { CGDisplayBounds($0).maxX }.max() ?? 0
    let origin = CGConfigureDisplayOrigin(config, id, Int32(right), 0)
    if origin != .success { CGCancelDisplayConfiguration(config); throw NSError(domain: "Origen", code: Int(origin.rawValue)) }
    let complete = CGCompleteDisplayConfiguration(config, .forAppOnly)
    guard complete == .success else { throw NSError(domain: "Configuración", code: Int(complete.rawValue)) }
    pump(1)
    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else {
        throw NSError(domain: "NSScreen no encontró la pantalla", code: 3)
    }
    let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 640, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false, screen: screen)
    window.title = "Prueba de escritorio independiente"
    window.contentView = NSTextField(labelWithString: "Esta ventana está en la pantalla virtual de la M5.")
    window.orderFrontRegardless()
    pump(1)
    let ownScreen = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    let newIDs = Set(displays()).subtracting(before)
    let independent = CGDisplayIsInMirrorSet(id) == 0 && CGDisplayMirrorsDisplay(id) == 0
    let separate = before.allSatisfy { !CGDisplayBounds($0).intersects(CGDisplayBounds(id)) }
    passed = newIDs == [id] && CGDisplayIsActive(id) != 0 && independent && separate && ownScreen == id
    print("Pantallas antes: \(before.count); durante: \(displays().count)")
    print("Resolución: \(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))")
    print("Pantalla nueva: \(newIDs == [id]); independiente: \(independent); sin superposición: \(separate)")
    print("Ventana en pantalla virtual: \(ownScreen == id)")
    window.orderOut(nil)
} catch { print("ERROR: \(error.localizedDescription)") }
display.stop()
}
pump(2)
let cleaned = Set(displays()) == before
print("Retirada dentro del proceso: \(cleaned). Verificar retirada al salir desde test-display.sh.")
print("Escritorio independiente: \(passed ? "PASS" : "FAIL")")
exit(passed ? 0 : 1)
