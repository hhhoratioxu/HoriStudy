import Foundation

enum NavigationDecision: Equatable {
    case allow, cancel, upgrade(URL), externalApp(String)
}

enum StudyNavigationPolicy {
    static func trusted(_ host: String) -> Bool {
        let value = host.lowercased()
        return ["chaoxing.com", "xueyinonline.com"].contains { value == $0 || value.hasSuffix("." + $0) }
    }
    static func decide(url: URL, sourceHost: String, mainFrame: Bool) -> NavigationDecision {
        if url.user != nil || url.password != nil { return .cancel }
        switch url.scheme?.lowercased() ?? "" {
        case "https", "about", "blob": return .allow
        case "javascript": return trusted(sourceHost) ? .allow : .cancel
        case "data": return mainFrame ? .cancel : .allow
        case "http":
            // Schools may use their own landing domain after an official login.
            // Upgrade top-level destinations to HTTPS; never fall back to HTTP.
            // This does not grant the school's domain course-automation privileges.
            guard let host = url.host, !host.isEmpty, trusted(host) || mainFrame,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .cancel }
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
            guard let upgraded = parts.url else { return .cancel }
            return .upgrade(upgraded)
        case "file": return .cancel
        default: return .externalApp(url.scheme ?? "unknown")
        }
    }
}
