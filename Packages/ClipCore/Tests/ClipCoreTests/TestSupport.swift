import Foundation
@testable import ClipCore

func jsonRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

func makeDisplayID(_ value: String = "display-1") throws -> DisplayID {
    try DisplayID(value)
}

func makeDisplay(
    id: String = "display-1",
    width: Int = 2560,
    height: Int = 1440,
    isMain: Bool = true
) throws -> DisplayDescriptor {
    DisplayDescriptor(
        id: try makeDisplayID(id),
        name: id,
        pixelSize: try PixelSize(width: width, height: height),
        isMain: isMain
    )
}

func makeSelection(
    displayID: String = "display-1",
    x: Double = 0.1,
    y: Double = 0.2,
    width: Double = 0.5,
    height: Double = 0.5
) throws -> CaptureSelection {
    CaptureSelection(
        displayID: try makeDisplayID(displayID),
        normalizedRect: try NormalizedRect(x: x, y: y, width: width, height: height)
    )
}

func makeInstant(_ seconds: TimeInterval) throws -> RecordingInstant {
    try RecordingInstant(seconds: seconds)
}

func makeHistoryItem(
    id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    updatedAt: Date? = nil,
    byteCount: Int64 = 1_000,
    duration: TimeInterval = 10,
    name: String = "clip-20260717-104218",
    path: String = "recordings/11111111-1111-1111-1111-111111111111.mp4",
    captureSessionSnapshot: CaptureSessionSnapshot? = nil
) throws -> RecordingHistoryItem {
    try RecordingHistoryItem(
        id: RecordingID(id),
        createdAt: createdAt,
        updatedAt: updatedAt,
        filename: RecordingFilename(validating: name),
        managedMaster: ManagedRecordingFile(relativePath: path),
        managedByteCount: byteCount,
        recordingDuration: duration,
        pixelSize: PixelSize(width: 1440, height: 900),
        frameRate: .thirty,
        audioConfiguration: .none,
        captureTarget: .region(makeSelection()),
        captureSessionSnapshot: captureSessionSnapshot,
        trimRange: TrimRange.full(recordingDuration: duration),
        exportConfiguration: .compact
    )
}
