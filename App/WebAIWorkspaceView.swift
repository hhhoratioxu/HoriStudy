import SwiftUI
import AppKit

struct WebAIWorkspaceView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var workspace: WebAIWorkspace
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("网页服务", selection: Binding(get: { workspace.selected }, set: { store.openWebAI($0) })) {
                    ForEach(WebAIProvider.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420).disabled(store.running || store.aiTestRunning)
                Spacer()
                Button("测试网页版作答") { store.testAIConnection() }.disabled(store.running || store.aiTestRunning)
            }.padding(12)
            HStack {
                Text("请在网页里登录并选择模型、Chat / Work 或联网模式。使用该网站给你的权益与额度。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在默认浏览器打开") { NSWorkspace.shared.open(workspace.selected.homeURL) }.font(.caption)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            if let browser = workspace.browsers[workspace.selected] {
                WebAIPageView(store: store, browser: browser)
            } else {
                ContentUnavailableView("打开 AI 网页", systemImage: "person.crop.circle.badge.checkmark", description: Text("选择上方服务，在网站中自行登录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(workspace.status).font(.caption).lineLimit(2)
                Spacer()
                Button("复制本题提示") { store.copySelectedWebPrompt() }.disabled(store.running || store.selected == nil)
                Button("导入复制的回答") { store.importWebAnswerFromClipboard() }.disabled(store.running || store.selected == nil)
            }.padding(10)
            if !store.aiTestMessage.isEmpty {
                HStack { Text(store.aiTestMessage).font(.caption).textSelection(.enabled); Spacer()
                    if store.aiTestRunning { Button("取消测试") { store.cancelAITest() } }
                }.padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
    }
}

private struct WebAIPageView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var browser: BrowserController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield")
                Text(browser.webView.url?.host ?? "正在打开官方网页…").textSelection(.enabled)
                Spacer()
                if browser.pages.count > 1 {
                    ForEach(browser.pages) { page in
                        Button(page.title) { store.pause(); browser.selectPage(page.id) }.lineLimit(1)
                        if page.openerID != nil { Button { store.pause(); browser.closePage(page.id) } label: { Image(systemName: "xmark") } }
                    }
                }
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.running || store.aiTestRunning)
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            if !browser.error.isEmpty { Text(browser.error).font(.caption).foregroundStyle(.orange).padding(8) }
            if !browser.navigationNotice.isEmpty { Text(browser.navigationNotice).font(.caption).foregroundStyle(.secondary).padding(8) }
            ZStack(alignment: .top) {
                BrowserView(browser: browser)
                if browser.loading { ProgressView().progressViewStyle(.linear).allowsHitTesting(false) }
            }
        }
    }
}
