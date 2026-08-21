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

    func load(_ url: URL) {
        currentURL = url
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
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
