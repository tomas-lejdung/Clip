import Foundation
import Security

enum LiveShareAccessCodeError: Error, Equatable {
    case secureRandomFailure(OSStatus)
}

enum LiveShareAccessCode {
    typealias RandomByteFiller = (UnsafeMutableRawBufferPointer) -> OSStatus

    /// A short, human-friendly secondary admission gate.
    ///
    /// The URL-fragment join capability is the high-entropy credential. This
    /// word is intentionally easy to relay separately and contributes 24 bits
    /// from three independently selected pronounceable syllables. Clip
    /// verifies it locally; the signaling service receives only encrypted
    /// admission messages.
    static func generate(
        using fillRandomBytes: RandomByteFiller = fillWithSystemRandomBytes
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        let status = bytes.withUnsafeMutableBytes(fillRandomBytes)
        guard status == errSecSuccess else {
            throw LiveShareAccessCodeError.secureRandomFailure(status)
        }
        precondition(onsets.count == 16 && rimes.count == 16)
        return bytes.map { byte in
            onsets[Int(byte >> 4)] + rimes[Int(byte & 0x0F)]
        }.joined()
    }

    private static func fillWithSystemRandomBytes(
        _ bytes: UnsafeMutableRawBufferPointer
    ) -> OSStatus {
        guard let baseAddress = bytes.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
    }

    /// Each byte maps its high and low nibble to one syllable without modulo
    /// bias. The combinations are short, speakable, ASCII, and case-insensitive
    /// under the existing proof normalization.
    static let onsets = [
        "B", "C", "D", "F", "G", "H", "J", "K",
        "L", "M", "N", "P", "R", "S", "T", "V",
    ]
    static let rimes = [
        "A", "E", "I", "O", "U", "AI", "AR", "EE",
        "EL", "EN", "ER", "IA", "IO", "OA", "ON", "OO",
    ]
}
