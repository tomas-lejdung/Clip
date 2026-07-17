import AppKit
import Darwin
import Foundation

private func fail(_ error: any Error, exitCode: Int32 = 70) -> Never {
    let message = "ClipTestHelper: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    Darwin.exit(exitCode)
}

let command: HelperCommand
do {
    command = try HelperArguments.parse(CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data((HelperArguments.usage + "\n").utf8))
    fail(error, exitCode: 64)
}

switch command {
case .status:
    do {
        try HelperJSON.write(HelperStatus.ready)
        Darwin.exit(0)
    } catch {
        fail(error)
    }

case let .validateMP4(url):
    Task {
        let report = await MP4Validator.validate(url)
        do {
            try HelperJSON.write(report)
            Darwin.exit(report.valid ? 0 : 65)
        } catch {
            fail(error)
        }
    }
    dispatchMain()

case .validatePasteboard:
    Task { @MainActor in
        guard let url = FileURLPasteboardResolver.firstFileURL(in: .general) else {
            let report = MP4Validator.rejectedReport(
                URL(fileURLWithPath: "/missing-pasteboard-file.mp4"),
                failure: "The pasteboard does not contain a local file URL."
            )
            do {
                try HelperJSON.write(report)
                Darwin.exit(65)
            } catch {
                fail(error)
            }
        }
        let report = await MP4Validator.validate(url)
        do {
            try HelperJSON.write(report)
            Darwin.exit(report.valid ? 0 : 65)
        } catch {
            fail(error)
        }
    }
    dispatchMain()

case let .generateMP4(url):
    Task {
        do {
            try await SyntheticMP4Generator.write(to: url)
            let report = await MP4Validator.validate(url)
            try HelperJSON.write(report)
            Darwin.exit(report.valid ? 0 : 65)
        } catch {
            fail(error)
        }
    }
    dispatchMain()

case let .renderFixture(url, frame):
    Task { @MainActor in
        do {
            try FixtureRenderer.renderPNG(to: url, frame: frame)
            let result = [
                "protocolVersion": "2",
                "renderedFixturePNGURL": url.absoluteString,
                "status": "ready",
            ]
            try HelperJSON.write(result)
            Darwin.exit(0)
        } catch {
            fail(error)
        }
    }
    dispatchMain()

case let .selfTest(workDirectory):
    Task { @MainActor in
        let report = await AcceptanceSelfTest.run(in: workDirectory)
        do {
            try HelperJSON.write(report)
            Darwin.exit(report.success ? 0 : 65)
        } catch {
            fail(error)
        }
    }
    dispatchMain()

case let .fixture(options):
    let application = NSApplication.shared
    let controller = AcceptanceFixtureController(options: options)
    application.delegate = controller
    application.run()
}
