import Foundation

@testable import ClipLiveShare

enum FixtureError: Error {
  case missing(String)
}

func fixtureData(_ name: String) throws -> Data {
  guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
    throw FixtureError.missing(name)
  }
  return try Data(contentsOf: url)
}

func jsonObjectsAreEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
  let left = try JSONSerialization.jsonObject(with: lhs) as AnyObject
  let right = try JSONSerialization.jsonObject(with: rhs) as AnyObject
  return left.isEqual(right)
}

func makeWindow(_ id: UInt32, app: String = "App") -> LiveShareWindowSource {
  LiveShareWindowSource(
    id: LiveShareWindowID(rawValue: id),
    windowName: "Window \(id)",
    appName: app
  )
}

func makeDisplay(_ id: UInt32 = 1) -> LiveShareDisplaySource {
  LiveShareDisplaySource(
    id: LiveShareDisplayID(rawValue: id),
    displayName: "Display \(id)"
  )
}

func makePublicRoom() throws -> ClipLiveSharePublicRoom {
  ClipLiveSharePublicRoom(
    name: try ClipLiveShareRoomName(rawValue: "CRISP-FROG-042"),
    viewerURL: URL(
      string: "https://clip.tineestudio.se/CRISP-FROG-042#v=1&key=fixture-public-key"
    )!
  )
}
