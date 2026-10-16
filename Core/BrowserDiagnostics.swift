import Foundation

struct BrowserDiagnostic: Codable {
    let time: Date
    let event: String
    let scheme: String
    let host: String
    let errorDomain: String
    let errorCode: Int

    init(event: String, url: URL? = nil, error: NSError? = nil) {
        time = Date(); self.event = event
        scheme = url?.scheme?.lowercased() ?? ""
        host = url?.host?.lowercased() ?? ""
        errorDomain = error?.domain ?? ""; errorCode = error?.code ?? 0
    }
}

enum BrowserFailure {
    case cancelled, unsupportedExternal(String), failure(String)
    static func failingURL(_ error: NSError) -> URL? {
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let value = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: value) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return failingURL(underlying) }
        return nil
    }
    static func classify(_ error: NSError) -> BrowserFailure {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return .cancelled }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return .cancelled }
        let url = failingURL(error)
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorUnsupportedURL,
           let scheme = url?.scheme?.lowercased(), !["https", "http", "about", "blob", "data"].contains(scheme) {
            return .unsupportedExternal(scheme)
        }
        let destination = url?.host.map { "，\($0)" } ?? ""
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorUnsupportedURL {
            return .failure("网页登录跳转未完成（错误 \(error.code)\(destination)）。请保留此页，查看「登录诊断」中的错误码。")
        }
        return .failure("网页加载失败（\(error.domain) \(error.code)\(destination)）：\(error.localizedDescription)")
    }
}
