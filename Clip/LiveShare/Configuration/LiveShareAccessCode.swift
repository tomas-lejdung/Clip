import Foundation
import Security

enum LiveShareAccessCodeError: Error, Equatable {
    case secureRandomFailure(OSStatus)
}

enum LiveShareAccessCode {
    typealias RandomByteFiller = (UnsafeMutableRawBufferPointer) -> OSStatus

    /// A cryptographically random 80-bit value. GoPeep v1 can read this access
    /// code, so UI calls it protection against accidental access rather than
    /// end-to-end authentication.
    static func generate(
        using fillRandomBytes: RandomByteFiller = fillWithSystemRandomBytes
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 10)
        let status = bytes.withUnsafeMutableBytes(fillRandomBytes)
        guard status == errSecSuccess else {
            throw LiveShareAccessCodeError.secureRandomFailure(status)
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func fillWithSystemRandomBytes(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> OSStatus {
        guard let baseAddress = bytes.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
    }
}
