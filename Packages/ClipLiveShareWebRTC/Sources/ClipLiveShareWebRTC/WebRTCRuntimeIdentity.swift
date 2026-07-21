public enum WebRTCRuntimeIdentity {
    public static let frameworkName = "WebRTC"
    public static let controlDataChannelLabel = "clip-control-v1"
    public static let maximumVideoSlots = 4
    /// Four video m-lines, one audio m-line, then the data-channel m-line.
    public static let maximumMediaLineIndex = maximumVideoSlots + 1

}
