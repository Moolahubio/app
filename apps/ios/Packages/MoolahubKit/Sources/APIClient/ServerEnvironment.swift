import Foundation

/// Which API server the app talks to.
///
/// - Debug, Simulator: `http://localhost:8787/api`.
/// - Debug, iPhone: `http://<this Mac>.local:8787/api`, the Mac's name coming
///   from the gitignored `Config/Local.xcconfig` (`DEV_MAC_HOST`). Both can be
///   overridden in Developer settings.
/// - Release: a placeholder HTTPS URL on the reserved `.invalid` domain. The
///   client refuses to send anything to it (`APIError.misconfigured`) and the
///   app shows a "not set up" screen, so a Release build can never talk to a
///   dev server or over plain HTTP. Replace it when a real API domain exists.
public enum ServerEnvironment {
    public static let releasePlaceholder = URL(string: "https://api.moolahub.invalid/api")!

    #if DEBUG
    // Dev servers exist only in Debug builds; a Release binary doesn't
    // contain these addresses at all.
    public static let simulatorDefault = URL(string: "http://localhost:8787/api")!
    /// The Debug Info.plist key that carries `DEV_MAC_HOST`.
    public static let devMacHostInfoKey = "MoolahubDevMacHost"

    /// The developer's Mac on the local network. `DEV_MAC_HOST` in the
    /// gitignored `Config/Local.xcconfig` reaches the Debug Info.plist as
    /// `devMacHostInfoKey`; without it, a placeholder to replace in Developer
    /// settings.
    public static let localNetworkDefault = localNetworkURL(
        host: Bundle.main.object(forInfoDictionaryKey: devMacHostInfoKey) as? String
    )

    static let localNetworkPlaceholder = URL(string: "http://your-mac.local:8787/api")!

    /// `http://<host>:8787/api` for a host name such as `my-mac.local` or an
    /// IPv4 address: dot-separated labels of 1 to 63 letters, digits and
    /// hyphens, none starting or ending with a hyphen, and no port. Anything
    /// else (missing, empty, an unexpanded build setting) gets the placeholder.
    static func localNetworkURL(host: String?) -> URL {
        let host = (host ?? "").trimmingCharacters(in: .whitespaces)
        let labelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !host.isEmpty && host.count <= 253 && labels.allSatisfy { label in
            (1...63).contains(label.count)
                && label.unicodeScalars.allSatisfy(labelCharacters.contains)
                && label.first != "-" && label.last != "-"
        }
        guard valid, let url = URL(string: "http://\(host):8787/api") else { return localNetworkPlaceholder }
        return url
    }
    #endif

    /// The build's default base URL.
    public static var defaultBaseURL: URL {
        #if DEBUG
        #if targetEnvironment(simulator)
        return simulatorDefault
        #else
        return localNetworkDefault
        #endif
        #else
        return releasePlaceholder
        #endif
    }

    /// The base URL to use now: the Developer settings override in Debug,
    /// otherwise the default.
    public static func currentBaseURL(defaults: UserDefaults = .standard) -> URL {
        #if DEBUG
        if let stored = defaults.string(forKey: overrideKey), case .success(let url) = validate(stored) {
            return url
        }
        #endif
        return defaultBaseURL
    }

    /// True when this build may send requests to `url`. Release requires
    /// HTTPS and refuses the placeholder.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        #if DEBUG
        return scheme == "http" || scheme == "https"
        #else
        return scheme == "https" && url.host?.lowercased().hasSuffix(".invalid") == false
        #endif
    }

    /// `host:port` for display ("localhost:8787").
    public static func displayHost(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    #if DEBUG
    public enum ValidationError: Error, Hashable, Sendable {
        case invalid

        public var message: String { "Enter a full URL, like http://localhost:8787/api." }
    }

    /// Developer settings rule (DESIGN.md §8.24): starts with `http://` or
    /// `https://`, has a host, and has no trailing slash.
    public static func validate(_ text: String) -> Result<URL, ValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              !trimmed.hasSuffix("/"),
              !trimmed.contains(" "),
              let url = URL(string: trimmed),
              let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil
        else { return .failure(.invalid) }
        return .success(url)
    }

    static let overrideKey = "dev.apiBaseURL"

    /// Debug-only persistence for the Developer settings override.
    public static func saveOverride(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.absoluteString, forKey: overrideKey)
    }

    public static func clearOverride(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: overrideKey)
    }

    public static func hasOverride(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: overrideKey) != nil
    }
    #endif
}
