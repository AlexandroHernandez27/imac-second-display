import Foundation
import Network

/// No acepta texto libre: claves, IP, rutas, contenido y descripciones de errores
/// nunca deben llegar al archivo. Las etiquetas son literales del código.
enum DiagnosticValue {
    case count(Int), measure(Double), flag(Bool), tag(StaticString)
    var json: Any {
        switch self {
        case .count(let value): return value
        case .measure(let value): return value.isFinite ? value : 0
        case .flag(let value): return value
        case .tag(let value): return value.description
        }
    }
}

final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    private let queue = DispatchQueue(label: "imac.diagnostics", qos: .utility)
    private var directory: URL?
    private var handle: FileHandle?
    private var size = 0
    private let limit: Int
    private var role = "unknown"
    private var session = UUID()
    private var storageFailed = false
    private var appInformation = [String: Any]()
    private let formatter = ISO8601DateFormatter()

    init(limit: Int = 1024 * 1024) { self.limit = limit }

    func configure(role: StaticString, directory override: URL? = nil) {
        queue.sync {
            self.role = role.description
            directory = override ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/iMac Second Display/\(self.role)", isDirectory: true)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            do {
                try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory!.path)
                try openCurrent()
            } catch { storageFailed = true }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            appInformation = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "arch": arch,
                "memory_gib": Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)), "protocol": 2]
            write("app_launch", fields: appInformation)
        }
    }

    func beginSession() {
        queue.async { self.session = UUID(); self.write("session_begin", fields: [:]) }
    }
    func event(_ name: StaticString, _ fields: [String: DiagnosticValue] = [:]) {
        queue.async { self.write(name.description, fields: fields.mapValues { $0.json }) }
    }
    func failure(_ name: StaticString, error: Error) {
        event(name, Self.errorFields(error))
    }
    static func errorFields(_ error: Error) -> [String: DiagnosticValue] {
        if let network = error as? NWError {
            switch network {
            case .posix(let code): return ["domain": .tag("posix"), "code": .count(Int(code.rawValue))]
            case .dns(let code): return ["domain": .tag("dns"), "code": .count(Int(code))]
            case .tls(let code): return ["domain": .tag("tls"), "code": .count(Int(code))]
            default: return ["domain": .tag("network_unknown")]
            }
        }
        // NSError descriptions/userInfo may contain addresses, filenames or app
        // names. Only known domains and numeric codes leave this boundary.
        var fields = [String: DiagnosticValue]()
        var current = error as NSError
        for depth in 0..<3 {
            let prefix = depth == 0 ? "" : "underlying\(depth)_"
            let domain: StaticString
            switch current.domain {
            case "com.apple.ScreenCaptureKit.SCStreamErrorDomain": domain = "SCStreamErrorDomain"
            case "SCStreamErrorDomain": domain = "SCStreamErrorDomain"
            case NSOSStatusErrorDomain: domain = "OSStatus"
            case NSPOSIXErrorDomain: domain = "posix"
            case NSCocoaErrorDomain: domain = "Cocoa"
            case NSURLErrorDomain: domain = "URL"
            case "AVFoundationErrorDomain": domain = "AVFoundation"
            case "CoreMediaErrorDomain": domain = "CoreMedia"
            case "SUSparkleErrorDomain": domain = "Sparkle"
            default: domain = "other"
            }
            fields[prefix + "domain"] = .tag(domain)
            fields[prefix + "code"] = .count(current.code)
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return fields
    }

    /// Includes prior launches; queue ordering flushes all events preceding export.
    func report() throws -> Data {
        try queue.sync {
            guard directory != nil, !storageFailed else { throw DisplayError("No se pudo guardar el registro local de diagnóstico.") }
            try handle?.synchronize()
            var data = Data("iMac Second Display · diagnóstico local\nSin claves, IP, nombres de equipo, rutas ni contenido de pantalla.\nLos horarios están en UTC. Comparar Sender y Receiver del mismo intento.\n\n".utf8)
            data.append(try JSONSerialization.data(withJSONObject: ["event": "report_context", "role": role, "data": appInformation], options: [.sortedKeys]))
            data.append(10)
            for index in [2, 1, 0] {
                let file = fileURL(index)
                if FileManager.default.fileExists(atPath: file.path) { data.append(try Data(contentsOf: file)) }
            }
            return data
        }
    }
    private func fileURL(_ index: Int) -> URL {
        directory!.appendingPathComponent(index == 0 ? "diagnostic.jsonl" : "diagnostic.\(index).jsonl")
    }
    private func openCurrent() throws {
        let file = fileURL(0)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DisplayError("No se pudo crear el registro.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        handle = try FileHandle(forWritingTo: file)
        size = Int(try handle!.seekToEnd())
    }
    private func write(_ name: String, fields: [String: Any]) {
        guard directory != nil, !storageFailed else { return }
        let entry: [String: Any] = ["time": formatter.string(from: Date()),
            "uptime_s": ProcessInfo.processInfo.systemUptime, "role": role,
            "session": session.uuidString, "event": name, "data": fields]
        do {
            var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            line.append(10)
            if size + line.count > limit {
                try handle?.close(); handle = nil
                let fm = FileManager.default
                if fm.fileExists(atPath: fileURL(2).path) { try fm.removeItem(at: fileURL(2)) }
                for index in [1, 0] where fm.fileExists(atPath: fileURL(index).path) {
                    try fm.moveItem(at: fileURL(index), to: fileURL(index + 1))
                }
                try openCurrent()
            }
            try handle?.write(contentsOf: line)
            size += line.count
        } catch { storageFailed = true; try? handle?.close(); handle = nil }
    }
    deinit { try? handle?.close() }
}
