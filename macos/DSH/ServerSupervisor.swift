import Darwin
import Foundation

private var reaperPid: pid_t = 0

private func reapSupervisedProcess() {
    if reaperPid > 0 {
        _ = kill(-reaperPid, SIGKILL)
    }
}

protocol ServerSupervisorDelegate: AnyObject {
    func supervisor(_ supervisor: ServerSupervisor, didReceiveLog chunk: String)
    func supervisor(_ supervisor: ServerSupervisor, didReportVersion version: String)
    func supervisor(_ supervisor: ServerSupervisor, didBecomeReady url: URL)
    func supervisor(_ supervisor: ServerSupervisor, didFail message: String)
    func supervisorDidExitUnexpectedly(_ supervisor: ServerSupervisor)
}

final class ServerSupervisor {
    weak var delegate: ServerSupervisorDelegate?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var outputHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var stopping = false
    private var becameReady = false
    private var reportedVersion = false
    private var logBuffer = ""
    private let readyRegex = try! NSRegularExpression(
        pattern: #"dsh web:\s+(https?://[^\s]+)"#,
        options: []
    )
    private let versionRegex = try! NSRegularExpression(
        pattern: #"dsh: version\s+(\S+)"#,
        options: []
    )
    private let ansiRegex = try! NSRegularExpression(
        pattern: #"\u001B\[[0-9;?]*[A-Za-z]"#,
        options: []
    )
    private let callbackQueue = DispatchQueue.main
    private var pollTimer: DispatchSourceTimer?
    private var selectedPort = 0
    private static var reaperInstalled = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid > 0
    }

    init() {
        Self.installReaper()
    }

    func start() {
        lock.lock()
        let alreadyRunning = pid > 0
        lock.unlock()
        if alreadyRunning {
            return
        }

        lock.lock()
        stopping = false
        becameReady = false
        reportedVersion = false
        logBuffer = ""
        selectedPort = 0
        lock.unlock()

        guard let port = NodeEnvironment.firstFreePort() else {
            LaunchLog.write("no free port in 3080-3180")
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.supervisor(self, didFail: "本地端口 3080–3180 均被占用，无法启动服务。")
            }
            return
        }

        guard let runtime = NodeEnvironment.bundledRuntime() else {
            LaunchLog.write("bundled runtime missing under \(Bundle.main.bundlePath)")
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.supervisor(
                    self,
                    didFail: "App 资源不完整（缺少内置 Node 或 dsh 运行时）。\n请重新运行 macos/build.sh 并安装到 /Applications。"
                )
            }
            return
        }

        lock.lock()
        selectedPort = port
        reportedVersion = true
        lock.unlock()

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let arguments = NodeEnvironment.webArguments(port: port, binScript: runtime.binScript)
        LaunchLog.write(
            "starting port=\(port) cwd=\(home) node=\(runtime.nodeExecutable) bin=\(runtime.binScript) version=\(runtime.version)"
        )
        emitLog("工作目录：\(home)\n")
        emitLog("dsh 版本：\(runtime.version)\n")
        emitLog("dsh commit：\(runtime.commit)\n")
        emitLog("内置 Node：\(runtime.nodeVersion)\n")
        emitLog("运行时：\(runtime.dshRoot)\n")
        emitLog("服务端口：\(port)\n")
        emitLog("执行：\(runtime.nodeExecutable) \(arguments.joined(separator: " "))\n")

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.supervisor(self, didReportVersion: runtime.version)
        }

        do {
            let handle = try ProcessGroup.spawn(
                executable: runtime.nodeExecutable,
                arguments: arguments,
                environment: NodeEnvironment.launchEnvironment(nodeBinDir: runtime.nodeBinDir),
                currentDirectory: home
            )
            LaunchLog.write("spawned pid=\(handle.pid)")
            attach(handle: handle)
            startHTTPProbe(port: port)
        } catch {
            LaunchLog.write("spawn failed: \(error.localizedDescription)")
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.supervisor(
                    self,
                    didFail: error.localizedDescription + "\n内置运行时启动失败。请重新运行 macos/build.sh。"
                )
            }
        }
    }

    func stopSync() {
        lock.lock()
        stopping = true
        let currentPid = pid
        let source = exitSource
        let handle = outputHandle
        let timer = pollTimer
        pid = 0
        exitSource = nil
        outputHandle = nil
        pollTimer = nil
        reaperPid = 0
        lock.unlock()

        timer?.cancel()
        source?.cancel()
        handle?.readabilityHandler = nil
        try? handle?.close()

        if currentPid > 0 {
            ProcessGroup.terminate(currentPid, waitSeconds: 5)
        }
    }

    func killImmediately() {
        lock.lock()
        stopping = true
        let currentPid = pid
        let timer = pollTimer
        pid = 0
        reaperPid = 0
        pollTimer = nil
        lock.unlock()
        timer?.cancel()
        if currentPid > 0 {
            ProcessGroup.killImmediately(currentPid)
        }
    }

    private func attach(handle: ProcessGroup.Handle) {
        lock.lock()
        pid = handle.pid
        outputHandle = handle.output
        reaperPid = handle.pid
        lock.unlock()

        handle.output.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                return
            }
            let chunk = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            self?.handleOutput(chunk)
        }

        let source = DispatchSource.makeProcessSource(
            identifier: handle.pid,
            eventMask: .exit,
            queue: callbackQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleProcessExit()
        }
        source.resume()

        lock.lock()
        exitSource = source
        lock.unlock()
    }

    private func handleOutput(_ chunk: String) {
        let cleaned = stripANSI(chunk)
        emitLog(cleaned)

        lock.lock()
        logBuffer.append(cleaned)
        let snapshot = logBuffer
        lock.unlock()

        if let url = parseReadyURL(in: snapshot) {
            markReady(url, source: "stdout")
        }

        lock.lock()
        let alreadyReported = reportedVersion
        lock.unlock()
        if !alreadyReported, let version = parseVersion(in: snapshot) {
            lock.lock()
            let shouldReport = !reportedVersion
            reportedVersion = true
            lock.unlock()
            if shouldReport {
                LaunchLog.write("version \(version)")
                callbackQueue.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.supervisor(self, didReportVersion: version)
                }
            }
        }
    }

    private func startHTTPProbe(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.8, repeating: 0.4)
        timer.setEventHandler { [weak self] in
            self?.probe(url)
        }
        timer.resume()
        lock.lock()
        pollTimer?.cancel()
        pollTimer = timer
        lock.unlock()
    }

    private func probe(_ url: URL) {
        lock.lock()
        let skip = becameReady || stopping
        lock.unlock()
        if skip { return }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return
            }
            self?.markReady(url, source: "http-\(http.statusCode)")
        }.resume()
    }

    private func markReady(_ url: URL, source: String) {
        lock.lock()
        if becameReady || stopping {
            lock.unlock()
            return
        }
        becameReady = true
        let timer = pollTimer
        pollTimer = nil
        lock.unlock()
        timer?.cancel()
        LaunchLog.write("ready via \(source) \(url.absoluteString)")
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.supervisor(self, didBecomeReady: url)
        }
    }

    private func handleProcessExit() {
        lock.lock()
        let wasStopping = stopping
        let wasReady = becameReady
        let currentPid = pid
        pid = 0
        reaperPid = 0
        let source = exitSource
        exitSource = nil
        let handle = outputHandle
        outputHandle = nil
        let timer = pollTimer
        pollTimer = nil
        lock.unlock()

        timer?.cancel()
        source?.cancel()
        handle?.readabilityHandler = nil
        if let handle {
            let leftover = handle.availableData
            if !leftover.isEmpty {
                let chunk = String(data: leftover, encoding: .utf8)
                    ?? String(decoding: leftover, as: UTF8.self)
                let cleaned = stripANSI(chunk)
                lock.lock()
                logBuffer.append(cleaned)
                lock.unlock()
                emitLog(cleaned)
            }
            try? handle.close()
        }
        if currentPid > 0 {
            _ = ProcessGroup.waitNonBlocking(currentPid)
        }
        LaunchLog.write("process exited pid=\(currentPid) stopping=\(wasStopping) ready=\(wasReady)")

        if wasStopping {
            return
        }

        if wasReady {
            delegate?.supervisorDidExitUnexpectedly(self)
        } else {
            lock.lock()
            let output = logBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.unlock()
            let detail: String
            if output.isEmpty {
                detail = "服务在就绪前退出，且没有捕获到运行时输出。"
            } else {
                let tail = String(output.suffix(4000))
                detail = "服务在就绪前退出。\n\n\(tail)"
            }
            delegate?.supervisor(self, didFail: detail)
        }
    }

    private func parseVersion(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = versionRegex.firstMatch(in: text, options: [], range: range),
              let versionRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[versionRange])
    }

    private func parseReadyURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = readyRegex.firstMatch(in: text, options: [], range: range),
              let urlRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let raw = String(text[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: ")].,"))
        return URL(string: raw)
    }

    private func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return ansiRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private func emitLog(_ chunk: String) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.supervisor(self, didReceiveLog: chunk)
        }
    }

    private static func installReaper() {
        guard !reaperInstalled else { return }
        reaperInstalled = true
        atexit(reapSupervisedProcess)
    }
}
