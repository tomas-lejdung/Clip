import Foundation
import Testing
@testable import Clip

struct ApplicationLiveShareRoleGateTests {
    @Test
    func hostAndViewerAreBothExclusiveApplicationRoles() {
        #expect(!ApplicationLiveShareRoleGate.hasActiveRole(
            isHosting: false,
            isViewing: false
        ))
        #expect(ApplicationLiveShareRoleGate.hasActiveRole(
            isHosting: true,
            isViewing: false
        ))
        #expect(ApplicationLiveShareRoleGate.hasActiveRole(
            isHosting: false,
            isViewing: true
        ))
        #expect(ApplicationLiveShareRoleGate.hasActiveRole(
            isHosting: true,
            isViewing: true
        ))
        #expect(ApplicationLiveShareRoleGate.hasActiveRole(
            isHosting: false,
            isViewing: false,
            isTransitioning: true
        ))
    }

    @Test
    func lateRoleCallbacksCannotMutateTheReplacementRole() {
        let priorRole = UUID()
        let replacementRole = UUID()

        #expect(ApplicationLiveShareRoleGate.acceptsCallback(
            activeToken: replacementRole,
            callbackToken: replacementRole
        ))
        #expect(!ApplicationLiveShareRoleGate.acceptsCallback(
            activeToken: replacementRole,
            callbackToken: priorRole
        ))
        #expect(!ApplicationLiveShareRoleGate.acceptsCallback(
            activeToken: nil,
            callbackToken: priorRole
        ))
    }

    @Test
    func viewerHandoffRequiresTheCurrentHostAndNoExistingViewer() {
        let hostRole = UUID()
        #expect(ApplicationLiveShareRoleGate.permitsHostPreparationHandoff(
            activeToken: hostRole,
            callbackToken: hostRole,
            isHosting: true,
            isViewing: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHostPreparationHandoff(
            activeToken: UUID(),
            callbackToken: hostRole,
            isHosting: true,
            isViewing: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHostPreparationHandoff(
            activeToken: hostRole,
            callbackToken: hostRole,
            isHosting: false,
            isViewing: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHostPreparationHandoff(
            activeToken: hostRole,
            callbackToken: hostRole,
            isHosting: true,
            isViewing: true
        ))
    }

    @Test
    func viewerIsInstalledOnlyByTheCurrentCompletedHandoff() {
        let transition = UUID()
        #expect(ApplicationLiveShareRoleGate.permitsHandoffCompletion(
            activeToken: transition,
            transitionToken: transition,
            isTransitioning: true,
            isPreparingForTermination: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHandoffCompletion(
            activeToken: UUID(),
            transitionToken: transition,
            isTransitioning: true,
            isPreparingForTermination: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHandoffCompletion(
            activeToken: transition,
            transitionToken: transition,
            isTransitioning: false,
            isPreparingForTermination: false
        ))
        #expect(!ApplicationLiveShareRoleGate.permitsHandoffCompletion(
            activeToken: transition,
            transitionToken: transition,
            isTransitioning: true,
            isPreparingForTermination: true
        ))
    }
}
