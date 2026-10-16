import Foundation

final class APIRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Even same-host redirects are refused. Never forward a key to an unconfigured destination.
        completionHandler(nil)
    }
}

final class APITransport {
    private let session: URLSession
    private let ownsSession: Bool
    init(session: URLSession? = nil) {
        if let session { self.session = session; ownsSession = false }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config); ownsSession = true
        }
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    func request(url: URL, key: String, body: [String: Any], provider: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw StudyError.message("API 地址无效。")
        }
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw StudyError.message("\(provider) 的 API 密钥为空或含有空格，请重新保存。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: APIRedirectBlocker()) }
        catch {
            try Task.checkCancellation()
            let code = (error as NSError).code
            throw StudyError.message("\(provider) 连接失败（网络错误 \(code)）。请检查网络和服务地址后手动重试。")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw StudyError.message("未收到有效的 API 响应。") }
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 300...399: message = "API 返回重定向，已阻止转发密钥。请核对服务的官方接口地址。"
            case 401: message = "API 密钥无效或已过期，请在设置中更新。"
            case 403: message = "当前账号或地区没有此 API 的访问权限。"
            case 429: message = "API 额度不足或请求过于频繁。请检查你自己的用量和限额。"
            case 400, 404, 422: message = "API 不接受当前模型或请求格式，请核对模型 ID、接入点及其格式支持。"
            default: message = "API 请求失败（HTTP \(http.statusCode)），请稍后手动重试。"
            }
            // Do not expose raw provider errors, which can echo keys or question data.
            throw StudyError.message("\(provider)：\(message)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudyError.message("\(provider) 返回的数据无法读取。")
        }
        return root
    }
}
