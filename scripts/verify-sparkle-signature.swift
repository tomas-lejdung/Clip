import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Sparkle signature verification failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("expected ARCHIVE PUBLIC_KEY_BASE64 SIGNATURE_BASE64")
}

let archivePath = CommandLine.arguments[1]
let encodedPublicKey = CommandLine.arguments[2]
let encodedSignature = CommandLine.arguments[3]

guard let publicKeyData = Data(base64Encoded: encodedPublicKey),
      publicKeyData.count == 32 else {
    fail("public key is not a canonical 32-byte Ed25519 key")
}
guard let signatureData = Data(base64Encoded: encodedSignature),
      signatureData.count == 64 else {
    fail("signature is not a canonical 64-byte Ed25519 signature")
}

do {
    let archiveData = try Data(
        contentsOf: URL(fileURLWithPath: archivePath),
        options: .mappedIfSafe
    )
    let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyData
    )
    guard publicKey.isValidSignature(signatureData, for: archiveData) else {
        fail("archive signature does not match Clip's embedded public key")
    }
} catch {
    fail("archive or public key could not be read")
}
