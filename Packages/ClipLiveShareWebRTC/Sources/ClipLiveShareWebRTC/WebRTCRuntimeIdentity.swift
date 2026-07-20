public enum WebRTCRuntimeIdentity {
    public static let frameworkName = "WebRTC"
    public static let controlDataChannelLabel = "gopeep-control"
    public static let maximumVideoSlots = 4
    public static let systemAudioTrackID = "audio0"
    public static let systemAudioStreamID = "gopeep-system-audio"
    /// Four video m-lines, one audio m-line, then the data-channel m-line.
    public static let maximumMediaLineIndex = maximumVideoSlots + 1
}
