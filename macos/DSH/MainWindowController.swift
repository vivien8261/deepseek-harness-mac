import AppKit

final class MainWindowController: NSWindowController {
    let supervisor = ServerSupervisor()
    private let webView = DSHWebView()
    private let overlay = LoadingOverlay()
    private var shuttingDown = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.setFrameAutosaveName("DSHMainWindow")
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        self.init(window: window)
        setupContent()
    }

    func startServer() {
        overlay.applyAppIcon()
        overlay.resetLog()
        overlay.showStarting()
        overlay.isHidden = false
        window?.title = "DeepSeek Harness"
        supervisor.start()
    }

    func beginShutdown(completion: @escaping () -> Void) {
        shuttingDown = true
        overlay.showStopping()
        overlay.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async { [supervisor] in
            supervisor.stopSync()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func setupContent() {
        supervisor.delegate = self
        webView.delegate = self
        overlay.onRetry = { [weak self] in
            self?.retry()
        }

        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window?.contentView = container
    }

    private func retry() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.supervisor.stopSync()
            DispatchQueue.main.async {
                self?.startServer()
            }
        }
    }

    @objc func reloadPage(_ sender: Any?) {
        if overlay.isHidden {
            webView.reload()
        } else {
            retry()
        }
    }
}

extension MainWindowController: ServerSupervisorDelegate {
    func supervisor(_ supervisor: ServerSupervisor, didReceiveLog chunk: String) {
        overlay.appendLog(chunk)
    }

    func supervisor(_ supervisor: ServerSupervisor, didReportVersion version: String) {
        overlay.showVersion(version)
        window?.title = "DeepSeek Harness  ·  \(version)"
    }

    func supervisor(_ supervisor: ServerSupervisor, didBecomeReady url: URL) {
        overlay.showOpening()
        overlay.appendLog("\n就绪：\(url.absoluteString)\n")
        webView.load(url)
    }

    func supervisor(_ supervisor: ServerSupervisor, didFail message: String) {
        overlay.isHidden = false
        overlay.showError(message)
        overlay.appendLog("\n\(message)\n")
    }

    func supervisorDidExitUnexpectedly(_ supervisor: ServerSupervisor) {
        overlay.isHidden = false
        overlay.showError("本地服务已退出。")
        overlay.appendLog("\n本地服务意外退出。\n")
    }
}

extension MainWindowController: DSHWebViewDelegate {
    func dshWebViewDidFinish(_ webView: DSHWebView) {
        guard !shuttingDown else { return }
        overlay.isHidden = true
    }

    func dshWebView(_ webView: DSHWebView, didFail message: String) {
        overlay.isHidden = false
        overlay.showError("页面加载失败：\(message)")
    }
}
