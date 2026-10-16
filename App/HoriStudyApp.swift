import AppKit
import SwiftUI

@main
struct HoriStudyApp: App {
    @StateObject private var store = StudyStore()
    var body: some Scene {
        WindowGroup {
            ContentView(store: store, browser: store.browser)
                .frame(minWidth: 1120, minHeight: 730)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 HoriStudy") { NSApp.orderFrontStandardAboutPanel(options: [:]) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("学习") {
                Button("打开学习通") { store.showWebAI = false; store.browser.open() }.keyboardShortcut("o")
                Button("识别当前页") { store.scan() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("开始核验") { store.start() }.disabled(store.running)
                Button("暂停全部") { store.pause() }.keyboardShortcut(".")
                Divider()
                Button("导入已核对题库…") { store.importBank() }
                Button("导出本页核验结果…") { store.exportResults() }
            }
        }
    }
}

private let accent = Color(red: 0.13, green: 0.39, blue: 0.88)

struct ContentView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var browser: BrowserController
    @State private var showWelcome = true
    @State private var urlText = "https://i.chaoxing.com"
    @State private var showDiagnostics = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(accent)
                    .frame(width: 36, height: 36).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("HoriStudy").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Preview 3").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    }
                    Text("学习通 · 资料查证与网页自动化").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("来源可查", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                Label("有疑问就暂停", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("选择网页登录或 API 连接")
                Button("课程网页") { store.showWebAI = false }
                Button("AI 网页") { store.openWebAI(store.webPreferences.answer) }
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if !store.showWebAI { HStack(spacing: 8) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.help("后退")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.help("前进")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新")
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    TextField("学习通或学校课程 HTTPS 地址", text: $urlText)
                        .textFieldStyle(.plain).onSubmit { showWelcome = false; store.pause(); browser.open(urlText) }
                }.padding(8).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                Button("打开学习通") { showWelcome = false; browser.open() }
                Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }.help("登录诊断")
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 8) }
            if !store.showWebAI && browser.pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(browser.pages) { page in
                            HStack(spacing: 6) {
                                Button(page.title) { store.pause(); browser.selectPage(page.id) }.lineLimit(1)
                                    .foregroundStyle(page.id == browser.activePageID ? accent : .secondary)
                                if page.openerID != nil {
                                    Button { store.pause(); browser.closePage(page.id) } label: { Image(systemName: "xmark") }.help("关闭此页并返回")
                                }
                            }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            Divider()
            HSplitView {
                Group {
                    if store.showWebAI { WebAIWorkspaceView(store: store, workspace: store.webAI) }
                    else { ZStack {
                    BrowserView(browser: browser)
                    if showWelcome { welcome }
                    if browser.loading { VStack { ProgressView().progressViewStyle(.linear); Spacer() }.allowsHitTesting(false) }
                    } }
                }.frame(minWidth: 650)
                inspector.frame(minWidth: 350, idealWidth: 385, maxWidth: 460)
            }
            Divider()
            HStack(spacing: 8) {
                if store.running || store.continuousVideo { ProgressView().controlSize(.small) }
                else { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.secondary) }
                Text(store.status).font(.caption).lineLimit(2)
                Spacer()
                Text("本次 API 请求 \(store.requestCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("网页消息 \(store.webMessageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("暂停全部") { store.pause() }.buttonStyle(.borderless).keyboardShortcut(".")
            }.padding(.horizontal, 16).padding(.vertical, 9).background(.bar)
        }
        .tint(accent)
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("登录诊断").font(.title2.bold()); Spacer(); Button("完成") { showDiagnostics = false } }
                Text("记录只保留在本机，包含协议、主机名和错误码。不会记录账号、密码、验证码、Cookie、页面路径或查询参数。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(browser.diagnosticText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24).frame(width: 680, height: 430)
        }
        .alert("操作提示", isPresented: Binding(get: { !store.error.isEmpty }, set: { if !$0 { store.error = "" } })) {
            Button("知道了") { store.error = "" }
        } message: { Text(store.error) }
        .onChange(of: browser.address) { _, value in urlText = value }
        .onChange(of: browser.error) { _, value in if !value.isEmpty { store.error = value } }
        .onChange(of: browser.navigationNotice) { _, value in if !value.isEmpty { store.status = value } }
    }

    var welcome: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(alignment: .leading, spacing: 26) {
                Label("HoriStudy / 学伴", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 12) {
                    Text("把每一道题，\n查得更清楚。").font(.system(size: 40, weight: .bold, design: .rounded)).lineSpacing(5)
                    Text("在课程网页中识别题目，保留答案依据。\n自动化处理重复操作，把不确定的地方留给你核对。")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                }
                VStack(alignment: .leading, spacing: 18) {
                    welcomeStep("1", "打开学习通", "在网页中登录，进入具体课程、作业或试卷。")
                    welcomeStep("2", "登录 AI 网页", "ChatGPT、DeepSeek、豆包、Gemini，使用网页中的账号与订阅。")
                    welcomeStep("3", "核对后提交", "符合条件的答案可以自动填写，提交前由你复核。")
                }
                HStack(spacing: 12) {
                    Button { showWelcome = false; browser.open() } label: {
                        Label("打开学习通", systemImage: "arrow.up.right").padding(.horizontal, 9).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("配置 AI") { store.showSettings = true }.controlSize(.large)
                }
                Text("AI 与网上题库都可能出错。图片题、无法识别的内容、冲突答案会暂停填写。")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading)
            }.frame(maxWidth: 590, alignment: .leading).padding(42)
        }
    }
    func welcomeStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(accent)
                .frame(width: 27, height: 27).background(accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) { Text(title).fontWeight(.semibold); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }

    var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("答案工作台").font(.title3.bold())
                    Text("\(store.results.count) 道题 · \(store.filledCount) 道已填写").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu { Button("导入题库…") { store.importBank() }; Button("导出核验结果…") { store.exportResults() } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.padding(16)
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Button { store.scan() } label: { Label("识别当前页", systemImage: "viewfinder") }.disabled(store.running)
                    Button { store.start() } label: { Label("开始核验", systemImage: "sparkle.magnifyingglass") }
                        .buttonStyle(.borderedProminent).disabled(store.running)
                }.controlSize(.large)
                Toggle("核验通过后自动填写", isOn: $store.autoFill).font(.caption).disabled(store.running)
                Toggle("本页全部填完后进入下一题", isOn: $store.autoNextQuestion).font(.caption).disabled(store.running)
                Text(store.answerConnectionMode == .web ?
                     "当前：\(store.webPreferences.answer.title) 网页作答 + \(store.webPreferences.review.title) 新会话复核。使用网站账号权益；网页引用仍需核对。" :
                     "当前：\(store.aiPreferences.answer.provider.title) API 作答 · 每题 \(store.aiPreferences.requestLimit) 次请求\(store.aiPreferences.useWebResearch ? "，含联网检索" : "，未联网草稿")，按你的 API 账号计费。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("填入已核验答案") { store.fillEligible() }.disabled(store.eligibleCount == 0 || store.running)
                    Spacer(minLength: 3)
                    Button("提交此页…") { store.submitPage() }.disabled(store.running || store.results.isEmpty)
                }
            }.padding(.horizontal, 16).padding(.bottom, 14)
            Divider()
            if store.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 29)).foregroundStyle(.tertiary)
                    Text("等待课程中的题目").font(.callout.bold())
                    Text("打开作业或试卷页面后，点击上方\n「识别当前页」。登录页不会发送给 AI。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(selection: $store.selectedQuestion) {
                    ForEach(store.results) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.question.kind.title).font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                                Spacer(); Text(row.status).font(.system(size: 10)).foregroundStyle(row.filled ? .green : .secondary) }
                            Text(row.question.stem).font(.system(size: 12)).lineLimit(2)
                        }.padding(.vertical, 5).tag(row.id)
                    }
                }.listStyle(.inset).frame(minHeight: 100, idealHeight: 180, maxHeight: 260)
                Divider()
                if let row = store.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(row.question.stem).font(.callout.weight(.medium)).textSelection(.enabled)
                            if !row.question.options.isEmpty {
                                ForEach(row.question.options) { option in
                                    HStack(alignment: .top, spacing: 7) {
                                        let chosen = row.answer?.draft.selectedOptionIDs.contains(option.id) == true
                                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? accent : .secondary)
                                        Text("\(option.label). \(option.text)").textSelection(.enabled)
                                    }.font(.caption)
                                }
                            }
                            if let answer = row.answer {
                                Label(answer.verification, systemImage: answer.eligible ? "checkmark.shield" : "exclamationmark.triangle")
                                    .font(.caption.bold()).foregroundStyle(answer.eligible ? accent : .orange)
                                ForEach(Array(answer.draft.textAnswers.enumerated()), id: \.offset) { index, value in
                                    Text("答案 \(index + 1)：\(value)").font(.caption).textSelection(.enabled)
                                }
                                Text(answer.draft.explanation).font(.caption).textSelection(.enabled)
                                if let attribution = answer.attribution { Text(attribution).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                                Text(answer.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                                if !answer.sources.isEmpty {
                                    Text("核对来源").font(.caption.bold()).padding(.top, 3)
                                    ForEach(Array(answer.sources.enumerated()), id: \.offset) { _, source in
                                        if let url = source.safeURL { Link(destination: url) { Label(source.title, systemImage: "arrow.up.right.square").font(.caption).multilineTextAlignment(.leading) } }
                                    }
                                }
                                if !answer.eligible && !row.filled && AnswerGate.validate(answer.draft, for: row.question) == nil {
                                    Button("我已核对，填入本题…") { store.fillSelectedAfterReview() }.font(.caption).disabled(store.running)
                                }
                            }
                            if !row.error.isEmpty { Text(row.error).font(.caption).foregroundStyle(.orange) }
                            Button("将这道题设为待重试") { store.retrySelected() }.font(.caption).disabled(store.running)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }.frame(maxHeight: .infinity)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label("课程视频", systemImage: "play.rectangle").font(.callout.bold()); Spacer()
                    Button(store.continuousVideo ? "暂停" : "连续播放") { store.continuousVideo ? store.pause() : store.startVideo() }.disabled(store.running) }
                Toggle("页面确认任务完成后进入下一节", isOn: $store.autoNextChapter).font(.caption)
                Text("正常播放，不跳时长。验证码或任务状态不明时暂停。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack { Text("本地题库 \(store.bankCount) 道").font(.caption).foregroundStyle(.secondary); Spacer(); Button("导入…") { store.importBank() }.font(.caption) }
            }.padding(16)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SettingsView: View {
    @ObservedObject var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var credentialProvider = AIProvider.openAI
    private var busy: Bool { store.running || store.aiTestRunning }
    private var answerProvider: Binding<AIProvider> {
        Binding(get: { store.aiPreferences.answer.provider }, set: { value in
            store.chooseAnswerProvider(value); credentialProvider = value
        })
    }
    private var reviewProvider: Binding<AIProvider> {
        Binding(get: { store.aiPreferences.review.provider }, set: { value in
            store.aiPreferences.review = AIModelChoice(provider: value)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(accent); Text("连接与核验设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Picker("连接方式", selection: $store.answerConnectionMode) {
                ForEach(AnswerConnectionMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
            ScrollView {
                if store.answerConnectionMode == .web {
                    webSettings
                } else {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("作答与复核").font(.headline)
                        HStack {
                            Picker("作答服务", selection: answerProvider) { ForEach(AIProvider.allCases) { Text($0.title).tag($0) } }.frame(width: 285)
                            TextField("作答模型 ID", text: $store.aiPreferences.answer.model).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Picker("复核服务", selection: reviewProvider) { ForEach(AIProvider.allCases) { Text($0.title).tag($0) } }.frame(width: 285)
                            TextField("复核模型 ID", text: $store.aiPreferences.review.model).textFieldStyle(.roundedBorder)
                        }
                        Text("可以用同一家或不同服务独立回答两次。模型 ID 需要在对应账号中可用；豆包也可填写你自己的推理接入点 ID。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("联网查证（使用 OpenAI）", isOn: $store.aiPreferences.useWebResearch)
                        if store.aiPreferences.useWebResearch {
                            HStack { Text("检索模型").frame(width: 76, alignment: .leading); TextField("支持 web_search 的 OpenAI 模型 ID", text: $store.aiPreferences.researchModel).textFieldStyle(.roundedBorder) }
                            Text("需额外保存 OpenAI 密钥。每题先检索，再由所选服务作答与复核，共 3 次请求；符合核验条件时可以自动填写。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("每题 2 次请求，无需 OpenAI 密钥（除非你选择它作答或复核）。答案仅为未联网草稿，不会自动填写；你核对后可填入本题。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Stepper("每次最多处理 \(store.maxQuestions) 道题", value: $store.maxQuestions, in: 1...100)
                    }.disabled(busy)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("各服务的 API 密钥").font(.headline)
                        Picker("配置服务", selection: $credentialProvider) { ForEach(AIProvider.allCases) { Text($0.title).tag($0) } }
                        if credentialProvider == .custom {
                            TextField("HTTPS Base URL，例如 https://api.example.com/v1", text: $store.aiPreferences.customBaseURL).textFieldStyle(.roundedBorder)
                            Toggle("接口支持 JSON Object 格式", isOn: $store.aiPreferences.customJSONMode).font(.caption)
                            Text("仅支持 Chat Completions 兼容 API。填写服务提供的 Base URL；网页聊天地址不能直接使用。改变地址后需要单独保存该地址的密钥。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let endpoint = try? credentialProvider.baseURL() {
                            Text("请求发送至：\(endpoint.absoluteString)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ProviderKeyView(provider: credentialProvider, preferences: store.aiPreferences)
                    }.disabled(busy)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接测试").font(.headline)
                        Text("用一道自编 HTTP 练习题检查当前作答、复核及可选检索配置，不需要登录学习通。测试会发送 \(store.aiPreferences.requestLimit) 次 API 请求，并按你的 API 账号计费。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("测试当前 AI 配置") { store.testAIConnection() }.disabled(busy)
                            if store.aiTestRunning { ProgressView().controlSize(.small); Button("取消测试") { store.cancelAITest() } }
                        }
                        if !store.aiTestMessage.isEmpty { Text(store.aiTestMessage).font(.caption).textSelection(.enabled) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数据与准确性").font(.headline)
                        Text("仅向你选择的服务发送题干、题型、选项、空格数和已有的检索资料；联网查证还会向 OpenAI 发送题目。账号密码和浏览器 Cookie 不会进入 API 请求。")
                        Text("密钥分别保存在这台 Mac 的钥匙串，已保存的内容不会回显。软件使用各家的开发者 API，需要对应 API 密钥及额度；不会创建密钥或更改账单。")
                        Text("两轮一致和可点击来源都不能保证正确。错误、分歧、无法完整读取的题目会暂停自动填写。")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
                }
            }
            HStack { Link("项目与使用说明", destination: URL(string: "https://github.com/hhhoratioxu/HoriStudy")!); Spacer(); Text("HoriStudy 0.2.0 Preview 3").foregroundStyle(.tertiary) }.font(.caption)
        }.padding(26).frame(width: 700, height: 710)
        .onAppear { credentialProvider = store.aiPreferences.answer.provider }
        .onDisappear { if store.answerConnectionMode == .api { store.cancelAITest() } }
    }

    var webSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("使用已登录网页的账号与订阅").font(.headline)
            Text("不需要 API 密钥。在真实网站中自行登录，模型、联网、Chat / Work 和订阅权益按网站显示为准。HoriStudy 不会把普通账号变成付费账号，也不会绕过额度或登录验证。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("作答网页", selection: $store.webPreferences.answer) { ForEach(WebAIProvider.allCases) { Text($0.title).tag($0) } }
            Picker("复核网页", selection: $store.webPreferences.review) { ForEach(WebAIProvider.allCases) { Text($0.title).tag($0) } }
            HStack {
                Button("登录作答网页") { dismiss(); store.openWebAI(store.webPreferences.answer) }
                Button("登录复核网页") { dismiss(); store.openWebAI(store.webPreferences.review) }
            }
            Text("每题开两次新会话，先作答、再复核，可能出现在网站的聊天历史中。网页中已有草稿、附件、正在生成的回答或登录验证时会暂停。网站长期记忆仍可能影响独立性。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("允许自动填写网页两轮一致的答案草稿", isOn: $store.webPreferences.autoFillAgreedDrafts)
            Text("网页中的链接尚未经过软件独立核实，两轮一致也可能一起出错。默认关闭此选项；关闭时可在核对后逐题填入。开启后还需主界面的“核验通过后自动填写”处于打开状态。")
                .font(.caption).foregroundStyle(.orange)
            Stepper("每次最多处理 \(store.maxQuestions) 道题", value: $store.maxQuestions, in: 1...100)
            Divider()
            Text("先用示例题检查连接").font(.headline)
            Text("先登录所选网页，再运行一道自编 HTTP 练习题。测试会发送两条网页消息并使用网站当前额度；不会填写课程页面。")
                .font(.caption).foregroundStyle(.secondary)
            Button("测试网页版作答") { dismiss(); store.testAIConnection() }
            if !store.aiTestMessage.isEmpty { Text(store.aiTestMessage).font(.caption).textSelection(.enabled) }
            Divider()
            Text("登录与数据").font(.headline)
            Text("各服务的登录状态保存在本应用独立的 WebKit 网站存储中。网页自动化只读取输入区、本次回答及其可见链接，不复制其他浏览器的 Cookie 或提取账号令牌。题目会发送给你选择的网站，并受该站的数据与聊天历史设置管理。")
                .font(.caption).foregroundStyle(.secondary)
            Text("有的网站可能限制内嵌浏览器登录，网页改版也可能使发送或读取失效。此时会暂停；可以在默认浏览器中手动发送“复制本题提示”的内容，再复制 JSON 回到“导入复制的回答”。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(busy).padding(.trailing, 8)
    }
}

struct ProviderKeyView: View {
    let provider: AIProvider
    let preferences: AIPreferences
    @State private var key = ""
    @State private var saved = false
    @State private var message = ""
    private var scope: CredentialScope? { try? preferences.scope(for: provider) }
    private var scopeID: String { scope.map { $0.service + ":" + $0.account } ?? "invalid" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(saved ? "已在本机保存此服务的密钥" : "尚未保存此服务的密钥", systemImage: saved ? "key.fill" : "key")
                .font(.caption).foregroundStyle(saved ? accent : .secondary)
            SecureField("输入新 API 密钥（已保存的密钥不会显示）", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Button("保存到钥匙串") {
                    guard let scope else { return }
                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { message = "密钥不能包含空格。"; return }
                    do { try KeychainStore.save(value, scope: scope); key = ""; saved = true; message = "密钥已保存。可在下方测试当前配置。" }
                    catch { message = error.localizedDescription }
                }.disabled(scope == nil || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("移除此密钥") {
                    guard let scope else { return }
                    do { try KeychainStore.save("", scope: scope); key = ""; saved = false; message = "已移除此服务的本机密钥。" }
                    catch { message = error.localizedDescription }
                }.disabled(scope == nil || !saved)
                Spacer()
                if let url = provider.consoleURL { Link("获取 API 密钥", destination: url) }
            }.font(.caption)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { refresh() }
        .onChange(of: scopeID) { _, _ in refresh() }
    }
    private func refresh() {
        key = ""; message = ""; saved = false
        guard let scope else { message = "请先填写有效的 HTTPS Base URL。"; return }
        do { saved = try KeychainStore.contains(scope: scope) }
        catch { message = error.localizedDescription }
    }
}
