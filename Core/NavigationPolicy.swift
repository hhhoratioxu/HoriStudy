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
            // Older official links still use HTTP. Preserve the destination using HTTPS.
            guard let host = url.host, trusted(host), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .cancel }
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
            guard let upgraded = parts.url else { return .cancel }
            return .upgrade(upgraded)
        case "file": return .cancel
        default: return .externalApp(url.scheme ?? "unknown")
        }
    }
}
