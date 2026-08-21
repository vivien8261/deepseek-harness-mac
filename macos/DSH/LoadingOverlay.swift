import AppKit

final class LoadingOverlay: NSView {
    var onRetry: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "DeepSeek Harness")
    private let statusLabel = NSTextField(labelWithString: "正在启动本地服务…")
    private let versionLabel = NSTextField(labelWithString: "dsh 版本检测中…")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logStorage = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showStarting() {
        retryButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在启动本地服务…"
        statusLabel.textColor = NSColor.secondaryLabelColor
        versionLabel.stringValue = "dsh 版本检测中…"
    }

    func showOpening() {
        retryButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "服务已就绪，正在打开界面…"
        statusLabel.textColor = NSColor.secondaryLabelColor
    }

    func showStopping() {
        retryButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "正在关闭本地服务…"
        statusLabel.textColor = NSColor.secondaryLabelColor
    }

    func showError(_ message: String) {
        retryButton.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = message
        statusLabel.textColor = NSColor.systemRed
    }

    func appendLog(_ chunk: String) {
        logStorage.append(chunk)
        if logStorage.count > 20_000 {
            logStorage = String(logStorage.suffix(16_000))
        }
        logView.string = logStorage
        logView.scrollToEndOfDocument(nil)
    }

    func showVersion(_ version: String) {
        versionLabel.stringValue = "dsh \(version)"
    }

    func resetLog() {
        logStorage = ""
        logView.string = ""
    }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 18
        iconView.layer?.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = NSColor(srgbRed: 0, green: 11 / 255, blue: 63 / 255, alpha: 1)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = NSColor.tertiaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.keyEquivalent = "\r"

        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = NSColor.secondaryLabelColor
        logView.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        logView.drawsBackground = true
        logView.textContainerInset = NSSize(width: 10, height: 8)

        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.hasHorizontalScroller = false
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 10
        logScroll.layer?.masksToBounds = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(versionLabel)
        addSubview(statusLabel)
        addSubview(spinner)
        addSubview(retryButton)
        addSubview(logScroll)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            versionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),

            spinner.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),

            retryButton.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),

            logScroll.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 28),
            logScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            logScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            logScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    func applyAppIcon() {
        iconView.image = NSApp.applicationIconImage
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
