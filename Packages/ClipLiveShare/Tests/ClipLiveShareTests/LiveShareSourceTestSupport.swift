@testable import ClipLiveShare

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
