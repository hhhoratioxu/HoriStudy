import Foundation
import CryptoKit

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI, deepSeek, doubao, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: return "OpenAI（ChatGPT）"
        case .deepSeek: return "DeepSeek"
        case .doubao: return "豆包 · 火山方舟"
        case .custom: return "自定义兼容接口"
        }
    }
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5.4"
        case .deepSeek: return "deepseek-flash"
        case .doubao: return "doubao-seed-2-1-pro-260915"
        case .custom: return ""
        }
    }
    var consoleURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .doubao: return URL(string: "https://ark.volcengine.com/region:cn-beijing/apikey")
        case .custom: return nil
        }
    }
    func baseURL(custom: String = "") throws -> URL {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1")!
        case .deepSeek: return URL(string: "https://api.deepseek.com")!
        case .doubao: return URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        case .custom:
            let value = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.percentEncodedPath == parts.path,
                  parts.port == nil || (1...65535).contains(parts.port!) else {
                throw StudyError.message("自定义地址需要 HTTPS Base URL，不能包含账号、密码、查询参数或片段。")
            }
            parts.scheme = "https"; parts.host = host.lowercased()
            if parts.port == 443 { parts.port = nil }
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            guard !parts.path.hasSuffix("/chat/completions"), !parts.path.hasSuffix("/responses"),
                  let url = parts.url else {
                throw StudyError.message("请填写 Base URL，例如 https://api.example.com/v1；不要填写完整的作答接口地址。")
            }
            return url
        }
    }
}

struct AIModelChoice: Codable, Equatable {
    var provider: AIProvider
    var model: String
    init(provider: AIProvider = .openAI, model: String? = nil) {
        self.provider = provider; self.model = model ?? provider.defaultModel
    }
}

struct AIPreferences: Codable, Equatable {
    var answer = AIModelChoice()
    var review = AIModelChoice()
    var useWebResearch = true
    var researchModel = AIProvider.openAI.defaultModel
    var customBaseURL = ""
    var customJSONMode = true

    var requiredProviders: [AIProvider] {
        var providers: Set<AIProvider> = [answer.provider, review.provider]
        if useWebResearch { providers.insert(.openAI) }
        return AIProvider.allCases.filter { providers.contains($0) }
    }
    var requestLimit: Int { useWebResearch ? 3 : 2 }

    func validate() throws {
        let models = [answer.model, review.model] + (useWebResearch ? [researchModel] : [])
        guard models.allSatisfy({ !$0.isEmpty && $0.count <= 200 && !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }) else {
            throw StudyError.message("请填写作答、复核及所需检索模型的准确名称；模型 ID 不能包含空格。")
        }
        for provider in requiredProviders { _ = try provider.baseURL(custom: customBaseURL) }
    }

    func scope(for provider: AIProvider) throws -> CredentialScope {
        try CredentialScope(provider: provider, customBaseURL: customBaseURL)
    }
}

struct CredentialScope: Equatable {
    let provider: AIProvider
    let service: String
    let account: String
    init(provider: AIProvider, customBaseURL: String = "") throws {
        self.provider = provider
        service = "com.hhhoratioxu.HoriStudy.\(provider.rawValue.lowercased())"
        // Keep the original OpenAI item readable. A custom key belongs to one exact Base URL.
        if provider == .custom {
            let base = try provider.baseURL(custom: customBaseURL).absoluteString
            let digest = SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
            account = "api-key-\(digest)"
        } else { account = "api-key" }
    }
}
