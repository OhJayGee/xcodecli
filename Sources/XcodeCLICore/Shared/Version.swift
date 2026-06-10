public enum Version {
    public static let source = "v1.2.1"
    public static let current: String = source

    #if DEBUG || XCODECLI_FORCE_DEV
    public static let buildChannel: String = "dev"
    #else
    public static let buildChannel: String = "release"
    #endif

    public static var isDev: Bool {
        buildChannel.lowercased().trimmingCharacters(in: .whitespaces) == "dev"
    }

    public static var line: String {
        var result = "xcodecli \(current)"
        if isDev {
            result += " (dev)"
        }
        return result
    }
}
