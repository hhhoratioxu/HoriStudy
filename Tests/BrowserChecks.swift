import AppKit
import Foundation
import WebKit

@MainActor
private final class LoginFixture: NSObject, WKURLSchemeHandler {
    var methods: [String] = []
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else { return }
        methods.append(request.httpMethod ?? "GET")
        let html: String
        switch url.path {
        case "/signin":
            html = """
            <html><title>Fixture sign in</title><body>
            <form method="post" action="horifixture://login/callback"><input name="fixture_nonce" value="synthetic-value"><button>Continue</button></form>
            </body></html>
            """
        case "/callback":
            html = """
            <html><title>Fixture callback</title><body><script>
            window.opener.postMessage('fixture-signed-in', '*'); window.close();
            </script></body></html>
            """
        default:
            html = """
            <html><title>Fixture start</title><body><div id="status">guest</div><script>
            window.addEventListener('message', event => {
                if(event.data === 'fixture-signed-in') { document.getElementById('status').textContent='signed-in'; document.title='Fixture signed in'; }
            });
            </script></body></html>
            """
        }
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
func runBrowserChecks() async throws {
    let fixture = LoginFixture()
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(fixture, forURLScheme: "horifixture")
    let browser = BrowserController(writesDiagnostics: false, configuration: configuration) { url, source, main in
        url.scheme == "horifixture" ? .allow : StudyNavigationPolicy.decide(url: url, sourceHost: source, mainFrame: main)
    }
    let root = browser.webView
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root; window.orderBack(nil)
    defer { window.orderOut(nil) }
    func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StudyError.message("Browser fixture timed out")
    }
    root.load(URLRequest(url: URL(string: "horifixture://login/start")!))
    try await waitFor { root.title == "Fixture start" && !browser.loading }
    let cookie = HTTPCookie(properties: [.domain: "fixture.example.org", .path: "/", .name: "HoriStudyFixture", .value: "synthetic-only", .secure: "TRUE"])!
    await withCheckedContinuation { continuation in root.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() } }
    let opened = try await root.callAsyncJavaScript("globalThis.fixturePopup = window.open('about:blank', 'fixture-login'); return fixturePopup !== null;", arguments: [:], in: nil, contentWorld: .page)
    check(opened as? Bool == true && browser.pages.count == 2, "blank login popup has a real WebKit window")
    let popup = browser.webView
    check(popup !== root, "popup keeps its opener page alive")
    let hasOpener = try await popup.callAsyncJavaScript("return window.opener !== null", arguments: [:], in: nil, contentWorld: .page)
    check(hasOpener as? Bool == true, "login popup retains window.opener")
    let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
        popup.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
    }
    check(cookies.contains { $0.name == "HoriStudyFixture" && $0.value == "synthetic-only" }, "popup shares the intended browser session store")
    _ = try await root.callAsyncJavaScript("fixturePopup.location.href='horifixture://login/signin'; return true", arguments: [:], in: nil, contentWorld: .page)
    try await waitFor { popup.title == "Fixture sign in" }
    _ = try await popup.callAsyncJavaScript("document.querySelector('form').submit(); return true", arguments: [:], in: nil, contentWorld: .page)
    try await waitFor { root.title == "Fixture signed in" && browser.pages.count == 1 }
    check(fixture.methods.contains("POST"), "popup form submission preserves POST navigation")
    check(browser.webView === root, "callback closes popup and restores opener tab")
    let status = try await root.callAsyncJavaScript("return document.querySelector('#status').textContent", arguments: [:], in: nil, contentWorld: .page)
    check(status as? String == "signed-in", "local login callback reaches its parent page")
    browser.webView(root, didFailProvisionalNavigation: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
    check(browser.error.isEmpty, "policy cancellation never creates a fatal page alert")
    _ = try await root.callAsyncJavaScript("window.location.href='chaoxing://fixture-probe?nonce=synthetic'; return true", arguments: [:], in: nil, contentWorld: .page)
    try await Task.sleep(nanoseconds: 250_000_000)
    check(browser.error.isEmpty && browser.webView === root && root.title == "Fixture signed in", "mobile-app probe preserves the working web login page")
    let fail = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL,
        userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://passport2.chaoxing.com/callback?token=PRIVATE_TEST_SENTINEL")!])
    browser.webView(root, didFailProvisionalNavigation: nil, withError: fail)
    check(!browser.error.isEmpty, "unexpected HTTPS login failures still surface")
    check(!browser.diagnosticText.contains("PRIVATE_TEST_SENTINEL") && !browser.diagnosticText.contains("callback?"), "native diagnostic log redacts sensitive callback parameters")
    print("Native browser login checks completed using local fixtures; no student account was used.")
}
