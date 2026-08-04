import ClipLiveShare
import Testing
@testable import Clip

@Suite("Live Share access codes")
struct LiveShareAccessCodeTests {
    @Test("syllable tables provide 24 bits without modulo bias")
    func syllables() {
        #expect(LiveShareAccessCode.onsets.count == 16)
        #expect(Set(LiveShareAccessCode.onsets).count == 16)
        #expect(LiveShareAccessCode.rimes.count == 16)
        #expect(Set(LiveShareAccessCode.rimes).count == 16)
    }

    @Test("three secure random bytes produce one uppercase pronounceable word")
    func deterministicSelection() throws {
        let first = try LiveShareAccessCode.generate { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            return 0
        }
        let last = try LiveShareAccessCode.generate { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: .max)
            return 0
        }

        #expect(first == "BABABA")
        #expect(last == "VOOVOOVOO")
        #expect(first.allSatisfy { $0.isUppercase })
        #expect(last.allSatisfy { $0.isUppercase })
    }

    @Test("secure random failures are reported instead of crashing Clip")
    func randomFailure() {
        #expect(throws: LiveShareAccessCodeError.secureRandomFailure(-50)) {
            try LiveShareAccessCode.generate { _ in -50 }
        }
    }

    @Test("new rooms honor the persisted Access Word default")
    @MainActor
    func initialRoomAccessWordDefault() {
        var generationCount = 0
        let enabled = ApplicationCoordinator.initialMeshAccessWord(
            for: .init(accessCodeEnabled: true)
        ) {
            generationCount += 1
            return "CALMOTTER"
        }
        let disabled = ApplicationCoordinator.initialMeshAccessWord(
            for: .init(accessCodeEnabled: false)
        ) {
            generationCount += 1
            return "SHOULDNOTGENERATE"
        }

        #expect(enabled == "CALMOTTER")
        #expect(disabled == nil)
        #expect(generationCount == 1)
    }

    @Test("join approval starts from creator snapshot, never candidate preference")
    @MainActor
    func initialRoomJoinApprovalDefault() {
        let enabled = LiveShareSettings(askBeforeJoining: true)
        let disabled = LiveShareSettings(askBeforeJoining: false)

        #expect(
            ApplicationCoordinator.initialMeshAskBeforeJoining(
                for: enabled,
                joiningRoom: false
            )
        )
        #expect(
            !ApplicationCoordinator.initialMeshAskBeforeJoining(
                for: disabled,
                joiningRoom: false
            )
        )
        #expect(
            !ApplicationCoordinator.initialMeshAskBeforeJoining(
                for: enabled,
                joiningRoom: true
            )
        )
    }
}
