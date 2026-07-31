import ClipLiveShare
import Foundation

private enum ValidatorCLIError: Error, LocalizedError {
  case usage
  case invalidDirectory
  case unsafeDirectoryPermissions
  case invalidLabels
  case missingReport(String)
  case unsafeReport(String)
  case reportTooLarge(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      """
      Usage: ClipNativeV3AcceptanceValidator \
      --stage ready|final --run-id ID --labels a,b,c \
      --expected-local-audio-tracks 0|1 \
      --reports-directory /private/absolute/path
      """
    case .invalidDirectory:
      "The acceptance reports directory is invalid."
    case .unsafeDirectoryPermissions:
      "The acceptance reports directory must be owner-only (0700)."
    case .invalidLabels:
      "Acceptance labels must contain exactly three or four unique values."
    case let .missingReport(label):
      "The signed report for \(label) is missing."
    case let .unsafeReport(label):
      "The signed report for \(label) is not a private regular file."
    case let .reportTooLarge(label):
      "The signed report for \(label) exceeds the 1 MiB limit."
    }
  }
}

private struct Arguments {
  let stage: ClipLiveShareNativeV3AcceptanceValidationStage
  let runIdentifier: String
  let labels: [String]
  let expectedLocalAudioTrackCount: Int
  let reportsDirectory: URL

  init(_ rawArguments: [String]) throws {
    var values: [String: String] = [:]
    var index = 0
    while index < rawArguments.count {
      let key = rawArguments[index]
      guard
        [
          "--stage",
          "--run-id",
          "--labels",
          "--expected-local-audio-tracks",
          "--reports-directory",
        ]
          .contains(key),
        values[key] == nil,
        index + 1 < rawArguments.count
      else {
        throw ValidatorCLIError.usage
      }
      values[key] = rawArguments[index + 1]
      index += 2
    }
    guard
      values.count == 5,
      let rawStage = values["--stage"],
      let stage = ClipLiveShareNativeV3AcceptanceValidationStage(
        rawValue: rawStage
      ),
      let runIdentifier = values["--run-id"],
      let rawLabels = values["--labels"],
      let rawExpectedAudioTrackCount =
        values["--expected-local-audio-tracks"],
      let expectedLocalAudioTrackCount = Int(rawExpectedAudioTrackCount),
      (0...1).contains(expectedLocalAudioTrackCount),
      let rawDirectory = values["--reports-directory"],
      rawDirectory.hasPrefix("/")
    else {
      throw ValidatorCLIError.usage
    }
    let labels = rawLabels.split(separator: ",", omittingEmptySubsequences: false)
      .map(String.init)
    guard
      (3...4).contains(labels.count),
      Set(labels).count == labels.count
    else {
      throw ValidatorCLIError.invalidLabels
    }
    self.stage = stage
    self.runIdentifier = runIdentifier
    self.labels = labels
    self.expectedLocalAudioTrackCount = expectedLocalAudioTrackCount
    reportsDirectory = URL(
      fileURLWithPath: rawDirectory,
      isDirectory: true
    ).standardizedFileURL
  }
}

private func validatePrivateDirectory(_ url: URL) throws {
  let values = try url.resourceValues(
    forKeys: [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
    ]
  )
  guard values.isDirectory == true, values.isSymbolicLink != true else {
    throw ValidatorCLIError.invalidDirectory
  }
  let attributes = try FileManager.default.attributesOfItem(
    atPath: url.path
  )
  guard
    let permissions = attributes[.posixPermissions] as? NSNumber,
    permissions.intValue & 0o077 == 0
  else {
    throw ValidatorCLIError.unsafeDirectoryPermissions
  }
}

private func loadReports(
  arguments: Arguments
) throws -> [ClipLiveShareSignedNativeV3AcceptanceReport] {
  try validatePrivateDirectory(arguments.reportsDirectory)
  return try arguments.labels.map { label in
    let url = arguments.reportsDirectory
      .appendingPathComponent("\(label).report.json", isDirectory: false)
      .standardizedFileURL
    let rootPath = arguments.reportsDirectory.path + "/"
    guard url.path.hasPrefix(rootPath) else {
      throw ValidatorCLIError.unsafeReport(label)
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ValidatorCLIError.missingReport(label)
    }
    let values = try url.resourceValues(
      forKeys: [
        .fileSizeKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ]
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: url.path
    )
    guard
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      (attributes[.posixPermissions] as? NSNumber)
        .map({ $0.intValue & 0o077 == 0 }) == true
    else {
      throw ValidatorCLIError.unsafeReport(label)
    }
    guard let size = values.fileSize, size <= 1_048_576 else {
      throw ValidatorCLIError.reportTooLarge(label)
    }
    return try JSONDecoder().decode(
      ClipLiveShareSignedNativeV3AcceptanceReport.self,
      from: Data(contentsOf: url, options: [.mappedIfSafe])
    )
  }
}

do {
  let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
  let reports = try loadReports(arguments: arguments)
  let summary = try ClipLiveShareNativeV3AcceptanceRunValidator.validate(
    reports,
    expectedRunIdentifier: arguments.runIdentifier,
    expectedProcessLabels: Set(arguments.labels),
    expectedLocalAudioTrackCount:
      arguments.expectedLocalAudioTrackCount,
    stage: arguments.stage
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(summary))
  FileHandle.standardOutput.write(Data([0x0A]))
} catch {
  FileHandle.standardError.write(
    Data("\(error.localizedDescription)\n".utf8)
  )
  exit(1)
}
