import ClipCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Clip

@MainActor
@Suite("Preview action lifetime")
struct PreviewViewModelTests {
    @Test("Done remains busy until durable close completes")
    func doneAwaitsPersistence() async throws {
        let probe = PreviewActionProbe()
        let actions = makeActions(
            done: { _ in
                try await Task.sleep(for: .milliseconds(20))
                await probe.append("done")
            }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)

        model.done()
        #expect(model.operation == .closing)
        try await waitUntil { model.operation == nil }
        #expect(await probe.events == ["done"])
        #expect(model.alert == nil)
    }

    @Test("Retake installs before committing and never discards a successful replacement")
    func retakeIsTwoPhase() async throws {
        let probe = PreviewActionProbe()
        let original = PreviewRecording.demo()
        let replacement = try PreviewRecording(
            id: RecordingID(UUID(uuidString: "30303030-3030-3030-3030-303030303030")!),
            sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-retake.mp4"),
            duration: 8,
            pixelSize: PixelSize(width: 1280, height: 720),
            filename: RecordingFilename(validating: "clip-retake.mp4"),
            trimRange: .full(recordingDuration: 8),
            exportConfiguration: .crisp
        )
        let actions = makeActions(
            retake: { _ in
                PreviewRetakeResult(
                    recording: replacement,
                    commitInstallation: {
                        await probe.append("commit")
                    },
                    discardReplacement: {
                        await probe.append("discard")
                    }
                )
            }
        )
        let model = PreviewViewModel(recording: original, actions: actions)

        model.retake()
        try await waitUntil { model.operation == nil }
        #expect(model.recording.id == replacement.id)
        #expect(await probe.events == ["commit"])
    }

    @Test("Delete requires confirmation and awaits managed deletion")
    func deleteRequiresConfirmation() async throws {
        let probe = PreviewActionProbe()
        let actions = makeActions(
            delete: { _ in
                try await Task.sleep(for: .milliseconds(20))
                await probe.append("delete")
            }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)

        model.requestDelete()
        #expect(model.isDeleteConfirmationPresented)
        #expect(await probe.events.isEmpty)
        model.confirmDelete()
        #expect(model.operation == .deleting)
        try await waitUntil { model.operation == nil }
        #expect(await probe.events == ["delete"])
    }

    @Test("Explicit Copy can close Preview only after the copy succeeds")
    func copyCanCloseAfterSuccess() async throws {
        let probe = PreviewActionProbe()
        let actions = makeActions(
            closeAfterCopy: true,
            done: { _ in await probe.append("done") }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)

        model.copy()
        try await waitUntil { model.operation == nil }

        #expect(await probe.events == ["done"])
        #expect(model.alert == nil)
    }

    @Test("A post-share History warning keeps successful Copy usable and visible")
    func copyHistoryWarningIsNotReportedAsFailure() async throws {
        let probe = PreviewActionProbe()
        let warning = "Clip couldn’t update History. The shared MP4 is still available."
        let actions = makeActions(
            closeAfterCopy: true,
            postShareWarning: warning,
            done: { _ in await probe.append("done") }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)

        model.copy()
        try await waitUntil { model.operation == nil }

        #expect(model.alert == nil)
        #expect(model.statusMessage?.contains("✓ Video copied") == true)
        #expect(model.statusMessage?.contains(warning) == true)
        #expect(await probe.events.isEmpty)
    }

    @Test("Copy confirmation reports the exact exported MP4 size")
    func copyConfirmationIncludesOutputFileSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("copied-video.mp4")
        try Data(repeating: 0, count: 5_800_000).write(to: outputURL)
        let model = PreviewViewModel(
            recording: .demo(),
            actions: PreviewActions(
                export: { request in
                    PreviewShareOutcome(
                        outputURL: request.sourceURL,
                        historyDisposition: .keepOriginal,
                        sourceFinalizationDeferred: false
                    )
                },
                copy: { _ in
                    PreviewShareOutcome(
                        outputURL: outputURL,
                        historyDisposition: .keepOriginal,
                        sourceFinalizationDeferred: false
                    )
                },
                save: { _ in nil },
                retake: { _ in nil },
                done: { _ in },
                delete: { _ in }
            )
        )
        #expect(model.outputSizeDescription == "Quality based — size varies")

        model.copy()
        try await waitUntil { model.operation == nil }

        #expect(ShareCompletionFormatting.fileByteCount(at: outputURL) == 5_800_000)
        #expect(model.statusMessage == "✓ Video copied — 5.8 MB")
        #expect(model.lastExportedByteCount == 5_800_000)
        let localizedSize = ByteCountFormatter.string(
            fromByteCount: 5_800_000,
            countStyle: .file
        )
        #expect(model.outputSizeDescription == "Actual output: \(localizedSize)")

        model.updateTrimEnd(12)
        #expect(model.outputSizeDescription == "Quality based — size varies")
    }

    @Test("Unknown technical errors are hidden while intentional messages remain actionable")
    func userFacingErrorPolicySeparatesTechnicalDetails() {
        let opaqueError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11_800,
            userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter private pipeline detail 0xDEADBEEF",
            ]
        )
        let hidden = UserFacingErrorPresentation.details(for: opaqueError)
        #expect(hidden.message == UserFacingErrorPresentation.genericMessage)
        #expect(!hidden.message.contains("AVAssetWriter"))
        #expect(hidden.technicalDescription.contains("AVAssetWriter"))

        let intentional = UserFacingErrorPresentation.details(
            for: UserSafePreviewError.exportUnavailable
        )
        #expect(intentional.message == "The exported video is no longer available. Try Copy again.")
        #expect(intentional.technicalDescription == intentional.message)

        let saveDirectory = UserFacingErrorPresentation.details(
            for: DefaultSaveDirectoryError.accessWasDenied(
                URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
            )
        )
        #expect(
            saveDirectory.message
                == "Clip could not keep access to the selected folder. Choose it again."
        )
    }

    @Test("A post-share History warning does not turn Save As into a failure")
    func saveHistoryWarningIsNotReportedAsFailure() async throws {
        let warning = "Clip couldn’t update History. The shared MP4 is still available."
        let model = PreviewViewModel(
            recording: .demo(),
            actions: makeActions(postShareWarning: warning)
        )

        model.saveAs()
        try await waitUntil { model.operation == nil }

        #expect(model.alert == nil)
        #expect(model.statusMessage?.contains("Saved clip-20260717-104218.mp4") == true)
        #expect(model.statusMessage?.contains(warning) == true)
    }

    @Test("A successful share exposes its exact MP4 to Reveal in Finder")
    func revealUsesLatestSharedFile() async throws {
        let probe = PreviewRevealProbe()
        let model = PreviewViewModel(
            recording: .demo(),
            actions: makeActions(reveal: { url in
                probe.url = url
            })
        )

        model.copy()
        try await waitUntil { model.operation == nil }
        let sharedURL = try #require(model.lastSharedFileURL)
        model.revealLastSharedFile()

        #expect(probe.url == sharedURL)
        #expect(
            sharedURL.deletingLastPathComponent()
                == model.recording.sourceURL.deletingLastPathComponent()
        )
        #expect(sharedURL.lastPathComponent == model.filenameText)
    }

    @Test("Trim, rename, and quality preset form one exact drag/export request")
    func dragRequestUsesCurrentEdits() throws {
        let model = PreviewViewModel(recording: .demo(), actions: makeActions())

        model.updateFilename("  dashboard-filters.MP4  ")
        model.updateTrimStart(3.25)
        model.updateTrimEnd(18.5)
        model.selectPreset(.smallest)

        let request = try #require(model.dragItem?.request)
        let expectedTrim = try TrimRange(startTime: 3.25, endTime: 18.5)
        #expect(request.recordingID == model.recording.id)
        #expect(request.sourceURL == model.recording.sourceURL)
        #expect(request.captureFrameRate == .thirty)
        #expect(request.filename.fileName == "dashboard-filters.mp4")
        #expect(request.trimRange == expectedTrim)
        #expect(request.configuration == ExportConfiguration(preset: .smallest))
        #expect(request.videoQualityPercent == 70)
        #expect(request.sourceVideoQualityPercent == 98)
        #expect(model.outputSizeDescription == "Quality based — size varies")
    }

    @Test("Every preset uses its independent configured quality")
    func presetQualityUsesCurrentSettings() throws {
        let duration: TimeInterval = 12
        let recording = try PreviewRecording(
            id: RecordingID(UUID(uuidString: "60606060-6060-6060-6060-606060606060")!),
            sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-estimate.mp4"),
            duration: duration,
            pixelSize: PixelSize(width: 2_222, height: 666),
            frameRate: .sixty,
            audioConfiguration: .systemAudioOnly,
            filename: RecordingFilename(validating: "clip-estimate.mp4"),
            trimRange: .full(recordingDuration: duration),
            exportConfiguration: .crisp,
            exportQualities: ExportQualitySettings(crisp: 99, compact: 72, smallest: 13),
            sourceVideoQualityPercent: 94
        )
        let model = PreviewViewModel(recording: recording, actions: makeActions())

        #expect(model.dragItem?.request.videoQualityPercent == 99)
        #expect(model.dragItem?.request.captureFrameRate == .sixty)
        #expect(model.dragItem?.request.sourceVideoQualityPercent == 94)
        model.selectPreset(.compact)
        #expect(model.dragItem?.request.videoQualityPercent == 72)
        model.selectPreset(.smallest)
        #expect(model.dragItem?.request.videoQualityPercent == 13)
    }

    @Test("Remove audio mutes Preview and changes the export request")
    func audioExportPreferenceControlsPreviewAndRequest() throws {
        let duration: TimeInterval = 12
        let recording = try PreviewRecording(
            id: RecordingID(UUID(uuidString: "70707070-7070-7070-7070-707070707070")!),
            sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-audio.mp4"),
            duration: duration,
            pixelSize: PixelSize(width: 1_440, height: 900),
            frameRate: .thirty,
            audioConfiguration: .systemAudioOnly,
            filename: RecordingFilename(validating: "clip-audio.mp4"),
            trimRange: .full(recordingDuration: duration),
            exportConfiguration: .compact
        )
        let model = PreviewViewModel(recording: recording, actions: makeActions())

        #expect(model.hasRecordedAudio)
        #expect(!model.isAudioRemoved)
        #expect(!model.player.isMuted)
        #expect(model.dragItem?.request.audioPreference == .keepAudio)

        model.setAudioRemoved(true)
        #expect(model.isAudioRemoved)
        #expect(model.player.isMuted)
        #expect(model.dragItem?.request.audioPreference == .removeAudio)

        model.setAudioRemoved(false)
        #expect(!model.isAudioRemoved)
        #expect(!model.player.isMuted)
        #expect(model.dragItem?.request.audioPreference == .keepAudio)
    }

    @Test("Copy and Done persist the same non-destructive audio export choice")
    func audioExportPreferencePersistsThroughShareAndDone() async throws {
        let probe = PreviewActionProbe()
        let duration: TimeInterval = 8
        let recording = try PreviewRecording(
            id: RecordingID(UUID(uuidString: "80808080-8080-8080-8080-808080808080")!),
            sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-audio-persist.mp4"),
            duration: duration,
            pixelSize: PixelSize(width: 1_280, height: 720),
            audioConfiguration: .microphoneAndSystemAudio,
            filename: RecordingFilename(validating: "clip-audio-persist.mp4"),
            trimRange: .full(recordingDuration: duration),
            exportConfiguration: .compact
        )
        let actions = PreviewActions(
            export: { request in
                PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            copy: { request in
                await probe.appendRequest(request)
                return PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            save: { _ in nil },
            retake: { _ in nil },
            done: { snapshot in await probe.appendSnapshot(snapshot) },
            delete: { _ in }
        )
        let model = PreviewViewModel(recording: recording, actions: actions)
        model.setAudioRemoved(true)

        model.copy()
        try await waitUntil { model.operation == nil }
        model.done()
        try await waitUntil { model.operation == nil }

        #expect(await probe.requests.first?.audioPreference == .removeAudio)
        #expect(await probe.snapshots.first?.exportAudioPreference == .removeAudio)
        #expect(model.recording.sourceURL == recording.sourceURL)
        #expect(model.recording.audioConfiguration == recording.audioConfiguration)
    }

    @Test("Trim handles clamp to a non-empty range and Reset Trim restores the source")
    func trimBoundsAndReset() {
        let model = PreviewViewModel(recording: .demo(), actions: makeActions())

        model.updateTrimEnd(4)
        model.updateTrimStart(100)
        #expect(model.trimStart == 3.9)
        #expect(model.trimEnd == 4)

        model.updateTrimEnd(-100)
        #expect(model.trimEnd == 4)

        model.resetTrim()
        #expect(model.trimStart == 0)
        #expect(model.trimEnd == model.duration)
        #expect(model.currentTime == 0)
    }

    @Test("Promised-file drag exports lazily and reports its retention outcome")
    func promisedDragIsLazy() async throws {
        let probe = PreviewActionProbe()
        let outputURL = URL(fileURLWithPath: "/tmp/lazy-drag.mp4")
        let actions = PreviewActions(
            export: { request in
                await probe.appendRequest(request)
                return PreviewShareOutcome(
                    outputURL: outputURL,
                    historyDisposition: .replaceOriginalWithExport,
                    sourceFinalizationDeferred: true
                )
            },
            copy: { request in
                PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            save: { _ in nil },
            retake: { _ in nil },
            done: { _ in },
            delete: { _ in }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)
        model.updateFilename("lazy-drag")

        let dragItem = try #require(model.dragItem)
        #expect(await probe.requests.isEmpty)

        let outcome = try await dragItem.resolveExport()
        #expect(await probe.requests.count == 1)
        #expect(outcome.outputURL == outputURL)

        #expect(model.sourceFinalizationDeferred)
        #expect(
            model.statusMessage
                == "Shared lazy-drag.mp4 — optimized original will update when Preview closes"
        )
    }

    @Test("Drag advertises the exact MP4 name and a browser-compatible file URL")
    func dragProvidesNamedContentAndFileURLRepresentations() async throws {
        let exportProbe = PreviewActionProbe()
        let reportProbe = PreviewDragReportProbe()
        let model = PreviewViewModel(recording: .demo(), actions: makeActions())
        model.updateFilename("github-upload")
        let request = try #require(model.dragItem?.request)
        let outputURL = URL(fileURLWithPath: "/tmp/github-upload.mp4")
        let dragItem = PreviewFileDragItem(
            id: request.recordingID,
            request: request,
            export: { request in
                await exportProbe.appendRequest(request)
                return PreviewShareOutcome(
                    outputURL: outputURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            reportFailure: { details in
                reportProbe.failures.append(details)
            },
            reportSuccess: { outcome in
                reportProbe.successURLs.append(outcome.outputURL)
            }
        )
        let provider = dragItem.makeItemProvider()

        #expect(await exportProbe.requests.isEmpty)
        #expect(provider.suggestedName == "github-upload.mp4")
        #expect(provider.registeredTypeIdentifiers.first == UTType.mpeg4Movie.identifier)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        #expect(provider.canLoadObject(ofClass: URL.self))

        let url = try await loadURLObject(from: provider)
        let mp4 = try await loadMP4Representation(from: provider)
        let outcome = try await dragItem.resolveExport()

        #expect(outcome.outputURL == outputURL)
        #expect(url == outputURL)
        #expect(mp4.url == outputURL)
        #expect(mp4.isInPlace)
        #expect(await exportProbe.requests.count == 1)
        #expect(reportProbe.successURLs == [outputURL])
        #expect(reportProbe.failures.isEmpty)
    }

    @Test("A failed drag reports once when receivers request both representations")
    func failedDragReportsOnlyOnceAcrossRepresentations() async throws {
        let exportProbe = PreviewActionProbe()
        let reportProbe = PreviewDragReportProbe()
        let model = PreviewViewModel(recording: .demo(), actions: makeActions())
        let request = try #require(model.dragItem?.request)
        let dragItem = PreviewFileDragItem(
            id: request.recordingID,
            request: request,
            export: { request in
                await exportProbe.appendRequest(request)
                throw PreviewViewModelTestError.exportFailed
            },
            reportFailure: { details in
                reportProbe.failures.append(details)
            },
            reportSuccess: { outcome in
                reportProbe.successURLs.append(outcome.outputURL)
            }
        )
        let provider = dragItem.makeItemProvider()

        do {
            _ = try await dragItem.resolveExport()
            Issue.record("The promised MP4 unexpectedly resolved")
        } catch {
            // Expected: the content representation owns the original export error.
        }
        do {
            _ = try await loadURLObject(from: provider)
            Issue.record("The URL-object representation unexpectedly resolved")
        } catch {
            // Expected: the second representation reuses the failed promise.
        }

        #expect(await exportProbe.requests.count == 1)
        #expect(reportProbe.failures.count == 1)
        #expect(reportProbe.successURLs.isEmpty)
    }

    @Test("Invalid filenames disable drag and block Copy before export starts")
    func invalidFilenameBlocksSharing() async {
        let probe = PreviewActionProbe()
        let actions = PreviewActions(
            export: { request in
                await probe.appendRequest(request)
                return PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            copy: { request in
                await probe.appendRequest(request)
                return PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            save: { _ in nil },
            retake: { _ in nil },
            done: { _ in },
            delete: { _ in }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)

        model.updateFilename("folder/unsafe.mp4")
        #expect(!model.canShare)
        #expect(model.dragItem == nil)
        #expect(model.filenameErrorMessage != nil)

        model.copy()
        #expect(model.operation == nil)
        #expect(model.alert?.title == "Invalid Filename")
        #expect(await probe.requests.isEmpty)
    }

    @Test("Copy receives the edited snapshot once even when clicked repeatedly while busy")
    func copyUsesEditedSnapshotOnce() async throws {
        let probe = PreviewActionProbe()
        let outputURL = URL(fileURLWithPath: "/tmp/renamed-copy.mp4")
        let actions = PreviewActions(
            export: { request in
                PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            copy: { request in
                await probe.appendRequest(request)
                try await Task.sleep(for: .milliseconds(20))
                return PreviewShareOutcome(
                    outputURL: outputURL,
                    historyDisposition: .replaceOriginalWithExport,
                    sourceFinalizationDeferred: true
                )
            },
            save: { _ in nil },
            retake: { _ in nil },
            done: { _ in },
            delete: { _ in }
        )
        let model = PreviewViewModel(recording: .demo(), actions: actions)
        model.updateFilename("renamed-copy")
        model.updateTrimStart(5)
        model.selectPreset(.crisp)

        model.copy()
        model.copy()
        #expect(model.operation == .copying)
        try await waitUntil { model.operation == nil }

        let requests = await probe.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.filename.fileName == "renamed-copy.mp4")
        #expect(request.trimRange.startTime == 5)
        #expect(request.configuration == .crisp)
        #expect(model.sourceFinalizationDeferred)
        #expect(
            model.statusMessage
                == "✓ Video copied — optimized original will update when Preview closes"
        )
    }

    @Test("Canceling Save As leaves Preview and history state unchanged")
    func cancelledSaveDoesNotMutatePreview() async throws {
        let probe = PreviewActionProbe()
        let original = PreviewRecording.demo()
        let actions = PreviewActions(
            export: { request in
                PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            copy: { request in
                PreviewShareOutcome(
                    outputURL: request.sourceURL,
                    historyDisposition: .keepOriginal,
                    sourceFinalizationDeferred: false
                )
            },
            save: { request in
                await probe.appendRequest(request)
                return nil
            },
            retake: { _ in nil },
            done: { _ in },
            delete: { _ in }
        )
        let model = PreviewViewModel(recording: original, actions: actions)
        model.updateFilename("save-cancelled")
        model.updateTrimEnd(12)

        model.saveAs()
        try await waitUntil { model.operation == nil }

        #expect(await probe.requests.count == 1)
        #expect(model.recording == original)
        #expect(model.filenameText == "save-cancelled")
        #expect(model.trimEnd == 12)
        #expect(model.statusMessage == nil)
        #expect(model.alert == nil)
    }

    @Test("Done persists the current rename, trim, and export preset snapshot")
    func donePersistsCurrentSnapshot() async throws {
        let probe = PreviewActionProbe()
        let actions = makeActions(done: { recording in
            await probe.appendSnapshot(recording)
        })
        let model = PreviewViewModel(recording: .demo(), actions: actions)
        model.updateFilename("persisted-edit")
        model.updateTrimStart(1.5)
        model.updateTrimEnd(20)
        model.selectPreset(.crisp)
        // The demo has no audio, so the default keep-audio preference remains stable.

        model.done()
        try await waitUntil { model.operation == nil }

        let snapshot = try #require(await probe.snapshots.first)
        let expectedTrim = try TrimRange(startTime: 1.5, endTime: 20)
        #expect(snapshot.filename.fileName == "persisted-edit.mp4")
        #expect(snapshot.trimRange == expectedTrim)
        #expect(snapshot.exportConfiguration == .crisp)
        #expect(snapshot.exportAudioPreference == .keepAudio)
    }

    @Test("A failed Retake commit restores the original and discards the replacement")
    func retakeCommitFailureRollsBack() async throws {
        let probe = PreviewActionProbe()
        let original = PreviewRecording.demo()
        let replacement = try PreviewRecording(
            id: RecordingID(UUID(uuidString: "40404040-4040-4040-4040-404040404040")!),
            sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-failed-retake.mp4"),
            duration: 7,
            pixelSize: PixelSize(width: 960, height: 540),
            filename: RecordingFilename(validating: "failed-retake.mp4"),
            trimRange: .full(recordingDuration: 7),
            exportConfiguration: ExportConfiguration(preset: .smallest)
        )
        let actions = makeActions(retake: { _ in
            PreviewRetakeResult(
                recording: replacement,
                commitInstallation: {
                    await probe.append("commit")
                    throw PreviewViewModelTestError.commitFailed
                },
                discardReplacement: {
                    await probe.append("discard")
                }
            )
        })
        let model = PreviewViewModel(recording: original, actions: actions)

        model.retake()
        try await waitUntil { model.operation == nil }

        #expect(model.recording == original)
        #expect(model.filenameText == original.filename.fileName)
        #expect(await probe.events == ["commit", "discard"])
        #expect(model.alert?.title == "Couldn’t Install Retake")
        #expect(model.alert?.message == UserFacingErrorPresentation.genericMessage)
    }

    @Test("A canceled Retake leaves the original draft untouched")
    func cancelledRetakeKeepsOriginal() async throws {
        let probe = PreviewActionProbe()
        let original = PreviewRecording.demo()
        let actions = makeActions(retake: { recording in
            await probe.appendSnapshot(recording)
            return nil
        })
        let model = PreviewViewModel(recording: original, actions: actions)
        model.updateFilename("edited-before-retake")
        model.updateTrimStart(4)

        model.retake()
        try await waitUntil { model.operation == nil }

        #expect(model.recording == original)
        #expect(model.filenameText == "edited-before-retake")
        #expect(model.trimStart == 4)
        let requestSnapshot = try #require(await probe.snapshots.first)
        #expect(requestSnapshot.filename.fileName == "edited-before-retake.mp4")
        #expect(requestSnapshot.trimRange.startTime == 4)
        #expect(model.alert == nil)
    }

    @Test("Retake restores the persisted capture session after relaunch")
    func retakeUsesPersistedCaptureSessionSnapshot() throws {
        var current = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        current.frameRate = .thirty
        current.showCursor = true
        current.audio = .none
        current.countdown = .off
        current.historyRetention = .thirtyDays
        let snapshot = CaptureSessionSnapshot(
            frameRate: .sixty,
            showCursor: false,
            audio: .microphoneAndSystemAudio,
            countdown: .fiveSeconds
        )
        let item = try makeRetakeHistoryItem(snapshot: snapshot)

        let plan = PreviewRetakePlan(
            historyItem: item,
            currentSettings: current
        )

        #expect(plan.target == item.captureTarget)
        #expect(plan.usesExactSessionSettings)
        #expect(plan.settings.frameRate == .sixty)
        #expect(plan.settings.showCursor == false)
        #expect(plan.settings.audio == .microphoneAndSystemAudio)
        #expect(plan.settings.countdown == .fiveSeconds)
        #expect(plan.settings.historyRetention == .thirtyDays)
    }

    @Test("Legacy Retake keeps historical media values and current cursor/countdown")
    func legacyRetakeFallbackRemainsBackwardCompatible() throws {
        var current = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        current.frameRate = .thirty
        current.showCursor = false
        current.audio = .none
        current.countdown = .oneSecond
        let item = try makeRetakeHistoryItem(snapshot: nil)

        let plan = PreviewRetakePlan(
            historyItem: item,
            currentSettings: current
        )

        #expect(!plan.usesExactSessionSettings)
        #expect(plan.settings.frameRate == item.frameRate)
        #expect(plan.settings.audio == item.audioConfiguration)
        #expect(plan.settings.showCursor == false)
        #expect(plan.settings.countdown == .oneSecond)
    }

    @Test("Preview timecodes cover short clips and hour-long recordings")
    func timecodeFormatting() {
        #expect(PreviewTimecodeFormatter.string(from: -1) == "0:00")
        #expect(PreviewTimecodeFormatter.string(from: 65.9) == "1:05")
        #expect(PreviewTimecodeFormatter.string(from: 3_661) == "1:01:01")
    }

    private func makeRetakeHistoryItem(
        snapshot: CaptureSessionSnapshot?
    ) throws -> RecordingHistoryItem {
        let duration: TimeInterval = 12
        return try RecordingHistoryItem(
            id: RecordingID(UUID(uuidString: "50505050-5050-5050-5050-505050505050")!),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            filename: RecordingFilename(validating: "retake-history.mp4"),
            managedMaster: ManagedRecordingFile(
                relativePath: "50505050-5050-5050-5050-505050505050.mp4"
            ),
            managedByteCount: 1_024,
            recordingDuration: duration,
            pixelSize: PixelSize(width: 1920, height: 1080),
            frameRate: snapshot?.frameRate ?? .sixty,
            audioConfiguration: snapshot?.audio ?? .systemAudioOnly,
            captureTarget: .fullscreen(try DisplayID("display-stable-1")),
            captureSessionSnapshot: snapshot,
            trimRange: .full(recordingDuration: duration),
            exportConfiguration: .compact
        )
    }

    private func makeActions(
        closeAfterCopy: Bool = false,
        postShareWarning: String? = nil,
        retake: @escaping PreviewRetakeAction = { _ in nil },
        done: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void = { _ in },
        delete: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void = { _ in },
        reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in }
    ) -> PreviewActions {
        let outcome: @Sendable (PreviewExportRequest, Bool) -> PreviewShareOutcome = { request, close in
            let outputURL = request.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent(request.filename.fileName)
            return PreviewShareOutcome(
                outputURL: outputURL,
                historyDisposition: .keepOriginal,
                sourceFinalizationDeferred: false,
                shouldClosePreview: close,
                postShareWarning: postShareWarning
            )
        }
        return PreviewActions(
            export: { outcome($0, false) },
            copy: { outcome($0, closeAfterCopy) },
            save: { outcome($0, false) },
            retake: retake,
            done: done,
            delete: delete,
            reveal: reveal
        )
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate() {
            guard clock.now < deadline else {
                throw PreviewViewModelTestError.timedOut
            }
            await Task.yield()
        }
    }

    private func loadURLObject(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: error ?? PreviewViewModelTestError.missingRepresentation
                    )
                }
            }
        }
    }

    private func loadMP4Representation(
        from provider: NSItemProvider
    ) async throws -> LoadedMP4Representation {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: UTType.mpeg4Movie.identifier
            ) { url, isInPlace, error in
                if let url {
                    continuation.resume(
                        returning: LoadedMP4Representation(url: url, isInPlace: isInPlace)
                    )
                } else {
                    continuation.resume(
                        throwing: error ?? PreviewViewModelTestError.missingRepresentation
                    )
                }
            }
        }
    }
}

private struct LoadedMP4Representation: Sendable {
    let url: URL
    let isInPlace: Bool
}

private actor PreviewActionProbe {
    private(set) var events: [String] = []
    private(set) var requests: [PreviewExportRequest] = []
    private(set) var snapshots: [PreviewRecording] = []

    func append(_ event: String) {
        events.append(event)
    }

    func appendRequest(_ request: PreviewExportRequest) {
        requests.append(request)
    }

    func appendSnapshot(_ recording: PreviewRecording) {
        snapshots.append(recording)
    }

}

@MainActor
private final class PreviewRevealProbe {
    var url: URL?
}

@MainActor
private final class PreviewDragReportProbe {
    var successURLs: [URL] = []
    var failures: [UserFacingErrorDetails] = []
}

private enum PreviewViewModelTestError: Error {
    case timedOut
    case commitFailed
    case exportFailed
    case missingRepresentation
}

private enum UserSafePreviewError: LocalizedError {
    case exportUnavailable

    var errorDescription: String? {
        "The exported video is no longer available. Try Copy again."
    }
}

@MainActor
@Suite("History workflow")
struct HistoryViewModelTests {
    @Test("Rename sheet commits an MP4-safe name to the authoritative index")
    func renamePersistsAuthoritativeIndex() async throws {
        let probe = HistoryActionProbe(index: HistoryDemoData.index())
        let model = HistoryViewModel(index: probe.index, actions: probe.actions())
        let item = try #require(model.items.first)

        model.beginRename(item)
        #expect(model.renameDraft?.id == item.id)
        let renamed = try RecordingFilename(validating: "  dashboard filters.MP4  ")
        model.rename(item.id, to: renamed)
        try await waitUntil { model.operation == nil }

        #expect(model.renameDraft == nil)
        #expect(model.index.item(id: item.id)?.filename.fileName == "dashboard filters.mp4")
        #expect(model.statusMessage == "Renamed to dashboard filters.mp4")
        #expect(probe.events == ["rename"])
    }

    @Test("Copy installs repository-returned removal instead of resurrecting history")
    func copyHonorsPostExportRemoval() async throws {
        let probe = HistoryActionProbe(index: HistoryDemoData.index())
        probe.removeAfterCopy = true
        let model = HistoryViewModel(index: probe.index, actions: probe.actions())
        let item = try #require(model.items.first)

        model.copy(item)
        try await waitUntil { model.operation == nil }

        #expect(model.index.item(id: item.id) == nil)
        #expect(model.items.count == 2)
        #expect(model.exports == probe.exportInventory.items)
        #expect(model.statusMessage == "✓ Video copied — 5.8 MB")
        #expect(probe.events == ["copy"])
    }

    @Test("Canceling Save As leaves the history index unchanged")
    func saveCancellationIsNonMutating() async throws {
        let initial = HistoryDemoData.index()
        let probe = HistoryActionProbe(index: initial)
        probe.cancelSave = true
        let model = HistoryViewModel(index: initial, actions: probe.actions())
        let item = try #require(model.items.first)

        model.saveAs(item)
        try await waitUntil { model.operation == nil }

        #expect(model.index == initial)
        #expect(model.statusMessage == nil)
        #expect(model.alert == nil)
        #expect(probe.events == ["save"])
    }

    @Test("Delete and Clear require confirmation and use returned indexes")
    func confirmedDestructiveActions() async throws {
        let probe = HistoryActionProbe(index: HistoryDemoData.index())
        let model = HistoryViewModel(index: probe.index, actions: probe.actions())
        let item = try #require(model.items.first)

        model.requestDelete(item)
        guard case let .confirmDelete(id, filename) = model.alert else {
            Issue.record("Expected delete confirmation")
            return
        }
        #expect(id == item.id)
        #expect(filename == item.filename.fileName)
        #expect(probe.events.isEmpty)

        model.confirmDelete(item.id)
        try await waitUntil { model.operation == nil }
        #expect(model.index.item(id: item.id) == nil)
        #expect(model.statusMessage == "Recording deleted")

        model.requestClearAll()
        guard case let .confirmClear(_, count) = model.alert else {
            Issue.record("Expected clear confirmation")
            return
        }
        #expect(count == 2)
        model.confirmClearAll()
        try await waitUntil { model.operation == nil }

        #expect(model.isEmpty)
        #expect(model.statusMessage == "History cleared")
        #expect(probe.events == ["delete", "refreshExports", "clear", "refreshExports"])
    }

    @Test("Managed exports link to intact sources while dangling exports remain listed")
    func exportSourceRelationships() throws {
        let index = HistoryDemoData.index()
        let inventory = HistoryDemoData.exports()
        let probe = HistoryActionProbe(index: index, exportInventory: inventory)
        let model = HistoryViewModel(
            index: index,
            exportInventory: inventory,
            actions: probe.actions()
        )

        let first = try #require(model.items.first)
        #expect(model.linkedExports(for: first.id).count == 3)
        #expect(model.exports.count == 5)
        #expect(model.exports.filter { model.sourceRecording(for: $0) == nil }.count == 1)
        #expect(model.exportStorageSummary.contains("5 exports"))
    }

    @Test("Deleting one export and purging all exports require confirmation")
    func confirmedExportDestructiveActions() async throws {
        let inventory = HistoryDemoData.exports()
        let probe = HistoryActionProbe(
            index: HistoryDemoData.index(),
            exportInventory: inventory
        )
        let model = HistoryViewModel(
            index: probe.index,
            exportInventory: inventory,
            actions: probe.actions()
        )
        let export = try #require(model.exports.first)

        model.requestDelete(export)
        guard case let .confirmDeleteExport(id, filename) = model.alert else {
            Issue.record("Expected export delete confirmation")
            return
        }
        #expect(id == export.id)
        #expect(filename == export.filename.fileName)

        model.confirmDeleteExport(export.id)
        try await waitUntil { model.operation == nil }
        #expect(!model.exports.contains { $0.id == export.id })
        #expect(model.statusMessage == "Export deleted")

        model.requestPurgeExports()
        guard case let .confirmPurgeExports(_, exportCount) = model.alert else {
            Issue.record("Expected export purge confirmation")
            return
        }
        #expect(exportCount == inventory.items.count - 1)

        model.confirmPurgeExports()
        try await waitUntil { model.operation == nil }
        #expect(model.exportsAreEmpty)
        #expect(model.statusMessage == "Exports deleted")
        #expect(probe.events == ["deleteExport", "purgeExports"])
    }

    @Test("A busy history action suppresses duplicate item actions")
    func busyStateSerializesActions() async throws {
        let probe = HistoryActionProbe(index: HistoryDemoData.index())
        probe.copyDelay = .milliseconds(20)
        let model = HistoryViewModel(index: probe.index, actions: probe.actions())
        let first = try #require(model.items.first)
        let second = try #require(model.items.dropFirst().first)

        model.copy(first)
        model.copy(second)
        #expect(model.operation == .copying(first.id))
        #expect(model.isBusy(first.id))
        #expect(!model.isBusy(second.id))
        try await waitUntil { model.operation == nil }

        #expect(probe.events == ["copy"])
    }

    @Test("History action failures return to idle with a user-facing operation title")
    func actionFailureIsPresented() async throws {
        let probe = HistoryActionProbe(index: HistoryDemoData.index())
        probe.failCopy = true
        let model = HistoryViewModel(index: probe.index, actions: probe.actions())
        let item = try #require(model.items.first)

        model.copy(item)
        try await waitUntil { model.operation == nil }

        guard case let .error(_, title, message) = model.alert else {
            Issue.record("Expected a history error alert")
            return
        }
        #expect(title == "Couldn’t Copy Video")
        #expect(message == UserFacingErrorPresentation.genericMessage)
        #expect(!message.contains("NSCocoaErrorDomain"))
        #expect(model.index.item(id: item.id) == item)
    }

    @Test("Post-share History failures are inline warnings after Copy and Save As")
    func postShareHistoryWarningsPreserveSuccess() async throws {
        let initial = HistoryDemoData.index()
        let probe = HistoryActionProbe(index: initial)
        let warning = "Clip couldn’t update History. The shared MP4 is still available."
        probe.postShareWarning = warning
        let model = HistoryViewModel(index: initial, actions: probe.actions())
        let item = try #require(model.items.first)

        model.copy(item)
        try await waitUntil { model.operation == nil }
        #expect(model.alert == nil)
        #expect(model.index == initial)
        #expect(model.statusMessage?.contains("✓ Video copied — 5.8 MB") == true)
        #expect(model.statusMessage?.contains(warning) == true)

        model.saveAs(item)
        try await waitUntil { model.operation == nil }
        #expect(model.alert == nil)
        #expect(model.index == initial)
        #expect(model.statusMessage?.contains("Saved \(item.filename.fileName)") == true)
        #expect(model.statusMessage?.contains(warning) == true)
        #expect(probe.events == ["copy", "save"])
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate() {
            guard clock.now < deadline else { throw HistoryViewModelTestError.timedOut }
            await Task.yield()
        }
    }
}

@MainActor
private final class HistoryActionProbe {
    var index: RecordingHistoryIndex
    var exportInventory: ManagedExportInventory
    var events: [String] = []
    var removeAfterCopy = false
    var cancelSave = false
    var failCopy = false
    var copyDelay: Duration?
    var postShareWarning: String?

    init(
        index: RecordingHistoryIndex,
        exportInventory: ManagedExportInventory = HistoryDemoData.exports()
    ) {
        self.index = index
        self.exportInventory = exportInventory
    }

    func actions() -> HistoryActions {
        HistoryActions(
            refresh: { [self] in
                events.append("refresh")
                return index
            },
            preview: { [self] _ in events.append("preview") },
            copy: { [self] item in
                events.append("copy")
                if let copyDelay { try await Task.sleep(for: copyDelay) }
                if failCopy {
                    throw NSError(
                        domain: "NSCocoaErrorDomain",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey: "NSCocoaErrorDomain private path detail",
                        ]
                    )
                }
                if let postShareWarning {
                    return HistoryShareOutcome(
                        refreshedIndex: nil,
                        outputByteCount: 5_800_000,
                        postShareWarning: postShareWarning
                    )
                }
                if removeAfterCopy {
                    index.remove(id: item.id)
                } else if var updated = index.item(id: item.id) {
                    try updated.registerSuccessfulExport(
                        at: Date(timeIntervalSince1970: 2_000_000_000)
                    )
                    index.upsert(updated)
                }
                return HistoryShareOutcome(
                    refreshedIndex: index,
                    exportInventory: exportInventory,
                    outputByteCount: 5_800_000
                )
            },
            save: { [self] item in
                events.append("save")
                guard !cancelSave else { return nil }
                if let postShareWarning {
                    return HistoryShareOutcome(
                        refreshedIndex: nil,
                        postShareWarning: postShareWarning
                    )
                }
                if var updated = index.item(id: item.id) {
                    try updated.registerSuccessfulExport(
                        at: Date(timeIntervalSince1970: 2_000_000_000)
                    )
                    index.upsert(updated)
                }
                return HistoryShareOutcome(refreshedIndex: index)
            },
            reveal: { [self] _ in events.append("reveal") },
            rename: { [self] id, filename in
                events.append("rename")
                if var item = index.item(id: id) {
                    try item.rename(
                        to: filename.fileName,
                        at: Date(timeIntervalSince1970: 2_000_000_000)
                    )
                    index.upsert(item)
                }
                return index
            },
            delete: { [self] id in
                events.append("delete")
                index.remove(id: id)
                return index
            },
            clear: { [self] in
                events.append("clear")
                index = try RecordingHistoryIndex()
                return index
            },
            refreshExports: { [self] in
                events.append("refreshExports")
                return exportInventory
            },
            revealExport: { [self] _ in
                events.append("revealExport")
            },
            deleteExport: { [self] id in
                events.append("deleteExport")
                let items = exportInventory.items.filter { $0.id != id }
                exportInventory = ManagedExportInventory(
                    items: items,
                    totalByteCount: items.reduce(0) { $0 + $1.byteCount }
                )
                return exportInventory
            },
            purgeExports: { [self] in
                events.append("purgeExports")
                exportInventory = .empty
                return exportInventory
            }
        )
    }
}

private enum HistoryViewModelTestError: Error {
    case timedOut
    case actionFailed
}

@MainActor
@Suite("Recording presentation workflow")
struct RecordingPresentationModelTests {
    @Test("Pause and Resume route to distinct actions for the current phase")
    func pauseResumeRouting() async throws {
        let probe = RecordingActionProbe()
        let model = RecordingPresentationModel(
            snapshot: .demoRecording,
            actions: probe.actions,
            clock: .fixed(100)
        )

        #expect(model.pauseResumeTitle == "Pause")
        model.togglePauseResume()
        try await waitUntil { !model.isPerformingAction }

        model.update(.demoPaused)
        #expect(model.pauseResumeTitle == "Resume")
        model.togglePauseResume()
        try await waitUntil { !model.isPerformingAction }

        #expect(probe.events == ["pause", "resume"])
    }

    @Test("Elapsed time advances only while actively recording")
    func elapsedExcludesPausedTime() {
        let model = RecordingPresentationModel(
            snapshot: RecordingPresentationSnapshot(
                phase: .recording,
                activeElapsedSeconds: 18,
                microphone: .off,
                systemAudio: .off
            ),
            actions: .noOp,
            clock: .fixed(100)
        )

        #expect(model.activeElapsedSeconds(at: 105.75) == 23.75)
        #expect(model.elapsedText(at: 105.75) == "00:23")

        model.update(RecordingPresentationSnapshot(
            phase: .paused,
            activeElapsedSeconds: 23.75,
            microphone: .off,
            systemAudio: .off
        ))
        #expect(model.activeElapsedSeconds(at: 9_999) == 23.75)
    }

    @Test("Pause and Finish stay disabled until the first captured frame")
    func firstFrameGatesRecordingControls() async throws {
        let probe = RecordingActionProbe()
        let model = RecordingPresentationModel(
            snapshot: RecordingPresentationSnapshot(
                phase: .recording,
                activeElapsedSeconds: 0,
                hasReceivedFirstFrame: false,
                microphone: .off,
                systemAudio: .off
            ),
            actions: probe.actions,
            clock: .fixed(100)
        )

        #expect(!model.canPauseOrResume)
        #expect(!model.canFinish)
        model.togglePauseResume()
        model.requestFinish()
        #expect(probe.events.isEmpty)

        model.requestCancel()
        try await waitUntil { !model.isPerformingAction }
        #expect(probe.events == ["cancel"])
    }

    @Test("Only active content over three seconds requires cancel confirmation")
    func cancelConfirmationThreshold() async throws {
        let probe = RecordingActionProbe()
        let exactlyThree = RecordingPresentationModel(
            snapshot: RecordingPresentationSnapshot(
                phase: .paused,
                activeElapsedSeconds: 3,
                microphone: .off,
                systemAudio: .off
            ),
            actions: probe.actions,
            clock: .fixed(100)
        )
        exactlyThree.requestCancel()
        try await waitUntil { !exactlyThree.isPerformingAction }
        #expect(!exactlyThree.isCancelConfirmationPresented)

        let meaningful = RecordingPresentationModel(
            snapshot: RecordingPresentationSnapshot(
                phase: .paused,
                activeElapsedSeconds: 3.01,
                microphone: .off,
                systemAudio: .off
            ),
            actions: probe.actions,
            clock: .fixed(100)
        )
        meaningful.requestCancel()
        #expect(meaningful.isCancelConfirmationPresented)
        #expect(probe.events == ["cancel"])
        meaningful.confirmCancel()
        try await waitUntil { !meaningful.isPerformingAction }
        #expect(probe.events == ["cancel", "cancel"])
    }

    @Test("Action errors return controls to idle and can be dismissed")
    func actionFailureRecovery() async throws {
        let probe = RecordingActionProbe()
        probe.failPause = true
        let model = RecordingPresentationModel(
            snapshot: .demoRecording,
            actions: probe.actions,
            clock: .fixed(100)
        )

        model.togglePauseResume()
        try await waitUntil { !model.isPerformingAction }
        #expect(model.actionErrorMessage == UserFacingErrorPresentation.genericMessage)
        #expect(model.canPauseOrResume)
        model.dismissActionError()
        #expect(model.actionErrorMessage == nil)
    }

    @Test("Recording duration formatting covers minute and hour boundaries")
    func durationFormatting() {
        #expect(RecordingDurationFormatter.string(seconds: -.infinity) == "00:00")
        #expect(RecordingDurationFormatter.string(seconds: 59.99) == "00:59")
        #expect(RecordingDurationFormatter.string(seconds: 60) == "01:00")
        #expect(RecordingDurationFormatter.string(seconds: 3_661) == "01:01:01")
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate() {
            guard clock.now < deadline else { throw RecordingPresentationTestError.timedOut }
            await Task.yield()
        }
    }
}

@MainActor
private final class RecordingActionProbe {
    var events: [String] = []
    var failPause = false

    var actions: RecordingPresentationActions {
        RecordingPresentationActions(
            pause: { [self] in
                events.append("pause")
                if failPause { throw RecordingPresentationTestError.actionFailed }
            },
            resume: { [self] in events.append("resume") },
            finish: { [self] in events.append("finish") },
            cancel: { [self] in events.append("cancel") }
        )
    }
}

private enum RecordingPresentationTestError: Error {
    case timedOut
    case actionFailed
}
