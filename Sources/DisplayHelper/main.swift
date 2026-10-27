import AppKit
import Darwin

// La vida de la pantalla queda acotada por este proceso. El EOF de stdin asegura
// su retirada incluso si el emisor termina inesperadamente.
let args = CommandLine.arguments
guard args.count == 4, let width = UInt32(args[1]), let height = UInt32(args[2]), let fps = Double(args[3]) else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let display = ISDVirtualDisplay()
do {
    try display.start(width: width, height: height, refreshRate: fps)
    FileHandle.standardOutput.write(Data("\(display.displayID)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
DispatchQueue.global().async {
    while !FileHandle.standardInput.availableData.isEmpty {}
    DispatchQueue.main.async { display.stop(); exit(0) }
}
app.run()
