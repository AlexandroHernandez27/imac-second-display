import Foundation
import Network

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DisplayError(message) }
}
func entries(_ report: Data) throws -> [[String: Any]] {
    try String(decoding: report, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("{") }.map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
}
do {
    let directory = URL(fileURLWithPath: ".build/diagnostics-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = Diagnostics(limit: 4096)
    let files = directory.appendingPathComponent("rotation")
    logger.configure(role: "Test", directory: files)
    logger.beginSession()
    // Many threads, frequent rotations, a final marker that must survive.
    DispatchQueue.concurrentPerform(iterations: 300) { index in logger.event("concurrent", ["index": .count(index)]) }
    logger.event("last_marker")
    let records = try entries(logger.report())
    try check(records.last?["event"] as? String == "last_marker", "Se perdieron eventos previos a exportar")
    try check(records.first?["event"] as? String == "report_context", "Falta contexto tras rotación")
    let retained = try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)
    try check(retained.count == 3, "La rotación no retuvo exactamente tres archivos")
    for file in retained {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try check((attrs[.size] as! NSNumber).intValue <= 4096, "El archivo excede el límite")
        try check((attrs[.posixPermissions] as! NSNumber).intValue == 0o600, "Archivo accesible a otros usuarios")
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: files.path)
    try check((permissions[.posixPermissions] as! NSNumber).intValue == 0o700, "Directorio no privado")
    let restarted = Diagnostics(limit: 4096)
    restarted.configure(role: "Test", directory: files)
    let afterRestart = try entries(restarted.report())
    try check(afterRestart.contains { $0["event"] as? String == "last_marker" }, "Reiniciar perdió el fallo anterior")
    print("PASS: escritura concurrente, rotación acotada, permisos y conservación al reiniciar.")

    let privacy = Diagnostics()
    privacy.configure(role: "Test", directory: directory.appendingPathComponent("privacy"))
    let sensitive = "FAKE_PRIVATE_KEY 192.168.254.99 /Users/test-person/private.txt secret-window-name"
    let nested = NSError(domain: NSOSStatusErrorDomain, code: -12909, userInfo: [NSLocalizedDescriptionKey: sensitive])
    privacy.failure("test_error", error: NSError(domain: "private-domain-" + sensitive, code: 42,
        userInfo: [NSLocalizedDescriptionKey: sensitive, NSUnderlyingErrorKey: nested]))
    privacy.failure("tls_error", error: NWError.tls(-9806))
    let report = try privacy.report()
    let text = String(decoding: report, as: UTF8.self)
    for forbidden in sensitive.split(separator: " ") {
        try check(!text.contains(forbidden), "Se filtró contenido privado")
    }
    let error = try entries(report).first { $0["event"] as? String == "test_error" }!["data"] as! [String: Any]
    try check(error["domain"] as? String == "other" && error["code"] as? Int == 42, "Error sin códigos seguros")
    try check(error["underlying1_code"] as? Int == -12909, "Se perdió el código subyacente")
    try check(text.contains("-9806") && text.contains("tls"), "Se perdió el error TLS")
    print("PASS: se conservan códigos TLS y subyacentes; se omiten dominios desconocidos, descripciones y userInfo privados.")

    let blocker = directory.appendingPathComponent("not-a-folder")
    try Data().write(to: blocker)
    let broken = Diagnostics()
    broken.configure(role: "Test", directory: blocker)
    broken.event("storage_failure")
    do { _ = try broken.report(); throw DisplayError("Una exportación fallida aparentó éxito") }
    catch let error as DisplayError where error.message == "No se pudo guardar el registro local de diagnóstico." {}
    print("PASS: fallo de almacenamiento comunicado sin bloquear la app.")
} catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
