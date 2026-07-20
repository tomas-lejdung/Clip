import Testing
@testable import ClipLiveShareWebRTC

@Suite("WebRTC adapter package")
struct WebRTCConfigurationTests {
    @Test("the adapter links the pinned WebRTC framework")
    func frameworkLinks() {
        #expect(WebRTCRuntimeIdentity.frameworkName == "WebRTC")
        #expect(WebRTCRuntimeIdentity.controlDataChannelLabel == "gopeep-control")
    }
}
