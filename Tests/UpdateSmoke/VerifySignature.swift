import Foundation
import CryptoKit

@main struct VerifySignature {
    static func main() throws {
        let args = CommandLine.arguments
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let signature = Data(base64Encoded: args[3])!
        guard publicKey.isValidSignature(signature, for: data) else { fatalError("La firma válida fue rechazada") }
        var altered = data; altered[altered.count / 2] ^= 1
        guard !publicKey.isValidSignature(signature, for: altered) else { fatalError("El ZIP alterado pasó verificación") }
        let otherKey = Curve25519.Signing.PrivateKey()
        guard !otherKey.publicKey.isValidSignature(signature, for: data) else { fatalError("Una clave ajena pasó verificación") }
        print("PASS: firma Ed25519 del ZIP; alteración de un byte y clave ajena rechazadas.")
    }
}
