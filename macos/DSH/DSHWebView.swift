import AppKit
import WebKit

protocol DSHWebViewDelegate: AnyObject {
    func dshWebView(_ webView: DSHWebView, didFail message: String)
    func dshWebViewDidFinish(_ webView: DSHWebView)
}

final class DSHWebView: NSView {
    weak var delegate: DSHWebViewDelegate?

    private let webView: WKWebView
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clear saved WebKit site data (cookies, localStorage/IndexedDB records,
    /// caches) before every page load. The persistent data store is required
    /// for a stable authentication flow (the 303 token exchange also issues
    /// the WebSocket cookie), but the previous run's frontend state restored
    /// from it crashes the session store at boot ("Assistant stream raw chunk
    /// must be a lossless JSON object") and leaves the conversation area
    /// blank. The launch-token page request mints a fresh cookie on every
    /// load, so clearing here is safe; all real data lives server-side in
    /// ~/.dsh.
    private func clearPreviousState(_ then: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            DispatchQueue.main.async(execute: then)
        }
    }

    func load(_ url: URL) {
        currentURL = url
        clearPreviousState { [weak self] in
            guard let self else { return }
            self.installLaunchTokenScript(url)
            self.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    func reload() {
        if webView.url != nil {
            webView.reload()
        } else if let currentURL {
            load(currentURL)
        }
    }

    private func setup() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func isLocalAppURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func isDSHServiceURL(_ url: URL) -> Bool {
        guard isLocalAppURL(url) else { return false }
        guard let origin = currentURL, isLocalAppURL(origin) else {
            return isLocalAppURL(url)
        }
        return effectivePort(url) == effectivePort(origin)
    }

    private func effectivePort(_ url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }

    private func isInPageResource(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "about" || scheme == "blob" || scheme == "data"
    }

    /// 0.1.3 authenticates the live WebSocket with an HttpOnly SameSite=Strict
    /// cookie. WKWebView often omits that cookie on the upgrade, so the page
    /// can submit turns while the journal stream stays empty. Attach the
    /// process launch token to `/api/remote.mux` as a fallback.
    private func installLaunchTokenScript(_ url: URL) {
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value ?? ""
        let escaped = token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let source = """
        (function () {
          var token = '\(escaped)';
          if (!token) return;
          var Orig = window.WebSocket;
          if (!Orig || Orig.__dshLaunchTokenPatched) return;
          function Wrapped(url, protocols) {
            try {
              var parsed = new URL(url, location.href);
              if (parsed.pathname === '/api/remote.mux' && !parsed.searchParams.has('token')) {
                parsed.searchParams.set('token', token);
                url = parsed.href;
              }
            } catch (error) {}
            return protocols === undefined ? new Orig(url) : new Orig(url, protocols);
          }
          Wrapped.prototype = Orig.prototype;
          Object.setPrototypeOf(Wrapped, Orig);
          Wrapped.CONNECTING = Orig.CONNECTING;
          Wrapped.OPEN = Orig.OPEN;
          Wrapped.CLOSING = Orig.CLOSING;
          Wrapped.CLOSED = Orig.CLOSED;
          Wrapped.__dshLaunchTokenPatched = true;
          window.WebSocket = Wrapped;
        })();
        """
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    private func relaxAuthCookies(in webView: WKWebView) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies where cookie.name.hasPrefix("dsh-auth-") {
                guard var properties = cookie.properties else { continue }
                properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
                guard let relaxed = HTTPCookie(properties: properties) else { continue }
                store.setCookie(relaxed)
            }
        }
    }

    @discardableResult
    private func openInDefaultBrowser(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "about" || url.absoluteString == "about:blank" {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

extension DSHWebView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if isInPageResource(url) || isDSHServiceURL(url) {
            decisionHandler(.allow)
            return
        }

        openInDefaultBrowser(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        relaxAuthCookies(in: webView)
        delegate?.dshWebViewDidFinish(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        delegate?.dshWebView(self, didFail: error.localizedDescription)
    }
}

extension DSHWebView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }
        if isDSHServiceURL(url) {
            webView.load(navigationAction.request)
        } else {
            openInDefaultBrowser(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}
