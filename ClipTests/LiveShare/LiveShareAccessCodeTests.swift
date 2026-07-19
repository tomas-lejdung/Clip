import Testing
@testable import Clip

@Suite("Live Share access codes")
struct LiveShareAccessCodeTests {
    @Test("codes are high-entropy uppercase hex values")
    func format() throws {
        let first = try LiveShareAccessCode.generate()
        let second = try LiveShareAccessCode.generate()
        #expect(first.count == 20)
        #expect(first.allSatisfy { $0.isNumber || ("A" ... "F").contains(String($0)) })
        #expect(first != second)
    }

    @Test("secure random failures are reported instead of crashing Clip")
    func randomFailure() {
        #expect(throws: LiveShareAccessCodeError.secureRandomFailure(-50)) {
            try LiveShareAccessCode.generate { _ in -50 }
        }
    }
}
