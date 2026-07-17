import Foundation
import XCTest
@testable import Clip

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testCompletionPersistsInAnIsolatedDefaultsSuite() throws {
        let suiteName = "com.tomaslejdung.clip.tests.onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingStore(defaults: defaults)

        XCTAssertFalse(store.isCompleted)
        store.markCompleted()
        XCTAssertTrue(store.isCompleted)

        let reloadedStore = OnboardingStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.isCompleted)
        reloadedStore.reset()
        XCTAssertFalse(store.isCompleted)
    }

    func testStoreBackedModelPersistsWhenFinalStepCompletes() throws {
        let suiteName = "com.tomaslejdung.clip.tests.onboarding-model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingStore(defaults: defaults)
        var completionCount = 0
        let model = OnboardingViewModel(
            store: store,
            initialStep: .preferences,
            currentScreenPermission: { .notDetermined },
            requestScreenPermission: { .granted },
            completion: { completionCount += 1 }
        )

        model.moveForward()

        XCTAssertTrue(store.isCompleted)
        XCTAssertEqual(completionCount, 1)
    }

    func testFourStepsAdvanceAndCompletionFiresOnce() {
        var completionCount = 0
        var permissionReadCount = 0
        let model = OnboardingViewModel(
            currentScreenPermission: {
                permissionReadCount += 1
                return .notDetermined
            },
            requestScreenPermission: { .granted },
            completion: { completionCount += 1 }
        )

        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(permissionReadCount, 1)
        model.moveBack()
        XCTAssertEqual(model.step, .welcome)

        model.moveForward()
        XCTAssertEqual(model.step, .screenRecording)
        model.moveForward()
        XCTAssertEqual(model.step, .optionalAudio)
        model.moveForward()
        XCTAssertEqual(model.step, .preferences)
        model.moveForward()
        model.moveForward()

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(permissionReadCount, 4)
    }

    func testOptionalAudioStepNeverRequestsPermission() async {
        var screenRequestCount = 0
        let model = OnboardingViewModel(
            currentScreenPermission: { .notDetermined },
            requestScreenPermission: {
                screenRequestCount += 1
                return .granted
            },
            completion: {}
        )

        model.moveForward()
        model.moveForward()
        XCTAssertEqual(model.step, .optionalAudio)
        XCTAssertEqual(screenRequestCount, 0)

        await model.requestScreenAccess()
        XCTAssertEqual(screenRequestCount, 1)
        XCTAssertEqual(model.screenPermission, .granted)
        XCTAssertFalse(model.isRequestingPermission)
    }

    func testShortcutConfigurationIsDelegatedToCoordinator() {
        var callbackCount = 0
        let model = OnboardingViewModel(
            currentScreenPermission: { .granted },
            requestScreenPermission: { .granted },
            configureShortcuts: { callbackCount += 1 },
            completion: {}
        )

        model.configureShortcuts()
        XCTAssertEqual(callbackCount, 1)
    }
}
