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
                Button("打开学习通") { store.browser.open() }.keyboardShortcut("o")
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
                        Text("Preview 2").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                    }
                    Text("学习通 · 资料查证与网页自动化").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("来源可查", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                Label("有疑问就暂停", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("设置模型与 API 密钥")
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HStack(spacing: 8) {
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
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 8)
            if browser.pages.count > 1 {
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
                ZStack {
                    BrowserView(browser: browser)
                    if showWelcome { welcome }
                    if browser.loading { VStack { ProgressView().progressViewStyle(.linear); Spacer() }.allowsHitTesting(false) }
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
                    welcomeStep("2", "识别并核验", "导入题库优先；未命中时联网查证，再做第二轮比对。")
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
                Text("每道未命中题库的题目最多使用 3 次 API 请求及联网检索，按你的 API 账号计费。")
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
                                Text(answer.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                                if !answer.sources.isEmpty {
                                    Text("核对来源").font(.caption.bold()).padding(.top, 3)
                                    ForEach(Array(answer.sources.enumerated()), id: \.offset) { _, source in
                                        if let url = source.safeURL { Link(destination: url) { Label(source.title, systemImage: "arrow.up.right.square").font(.caption).multilineTextAlignment(.leading) } }
                                    }
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
    @State private var key = ""
    @State private var message = ""
    @State private var keyWasLoaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Image(systemName: "slider.horizontal.3").foregroundStyle(accent); Text("连接与核验设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenAI API").font(.headline)
                Text("输入你自己的 API 密钥。密钥只保存在这台 Mac 的钥匙串，网页脚本无法读取。")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("API 密钥", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存到钥匙串") {
                        do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); store.keyConfigured = !key.isEmpty; message = key.isEmpty ? "已移除本机 API 密钥。" : "密钥已保存。首次核验时会实际连接 API。" }
                        catch { message = error.localizedDescription }
                    }.disabled(!keyWasLoaded)
                    Button("移除密钥") { do { try KeychainStore.save(""); key = ""; store.keyConfigured = false; message = "已移除密钥。" } catch { message = error.localizedDescription } }
                    Spacer()
                    Link("获取 API 密钥", destination: URL(string: "https://platform.openai.com/api-keys")!)
                }.font(.caption)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("两轮核验").font(.headline)
                HStack { Text("答案模型").frame(width: 76, alignment: .leading); TextField("模型名称", text: $store.answerModel).textFieldStyle(.roundedBorder) }
                HStack { Text("复核模型").frame(width: 76, alignment: .leading); TextField("模型名称", text: $store.reviewModel).textFieldStyle(.roundedBorder) }
                Text("答案模型需要支持 Responses API、web_search 和结构化输出；复核模型需要支持结构化输出。你可以使用自己有权限的不同模型。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("每次最多处理 \(store.maxQuestions) 道题", value: $store.maxQuestions, in: 1...100)
            }.disabled(store.running)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("数据与准确性").font(.headline)
                Text("主动开始核验时，仅向 OpenAI 发送识别出的题干、题型、选项和空格数。联网检索还会使用与题目相关的搜索词；账号密码和浏览器 Cookie 不会进入请求。")
                Text("每道未命中题库的题目包含检索、答案、复核 3 次请求；API 和检索按你的账号计费。软件不会创建密钥或修改账单。")
                Text("两轮一致只能降低部分错误，无法保证正确。导入题库的答案、主观题和资料本身也需要核对。")
            }.font(.caption).foregroundStyle(.secondary)
            HStack { Link("项目与使用说明", destination: URL(string: "https://github.com/hhhoratioxu/HoriStudy")!); Spacer(); Text("HoriStudy 0.1.1 Preview 2").foregroundStyle(.tertiary) }.font(.caption)
        }.padding(28).frame(width: 590)
        .onAppear {
            do { key = try KeychainStore.read(); keyWasLoaded = true; store.keyConfigured = !key.isEmpty }
            catch { message = error.localizedDescription }
        }
    }
}
