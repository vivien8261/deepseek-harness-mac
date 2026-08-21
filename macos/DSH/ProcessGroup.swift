import Darwin
import Foundation

@_silgen_name("proc_listchildpids")
private func proc_listchildpids(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

enum ProcessGroupError: LocalizedError {
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            return "无法启动进程（posix_spawn: \(code)）"
        }
    }
}

enum ProcessGroup {
    struct Handle {
        let pid: pid_t
        let output: FileHandle
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String
    ) throws -> Handle {
        let outputPipe = Pipe()
        let readHandle = outputPipe.fileHandleForReading
        let writeHandle = outputPipe.fileHandleForWriting

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, writeHandle.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, writeHandle.fileDescriptor, STDERR_FILENO)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setpgroup(&attrs, 0)
        posix_spawnattr_setflags(
            &attrs,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        let argv = [executable] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }

        let pid = try currentDirectory.withCString { cwd in
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
            return try withCStringArray(argv) { argvPointer in
                try withCStringArray(env) { envPointer in
                    try executable.withCString { path in
                        var spawned: pid_t = 0
                    let status = posix_spawn(
                        &spawned,
                        path,
                        &fileActions,
                        &attrs,
                        argvPointer,
                        envPointer
                    )
                    guard status == 0 else {
                        LaunchLog.write("posix_spawn status=\(status) errno=\(errno)")
                        throw ProcessGroupError.spawnFailed(status)
                    }
                    LaunchLog.write("posix_spawn ok pid=\(spawned)")
                    return spawned
                    }
                }
            }
        }

        try writeHandle.close()
        return Handle(pid: pid, output: readHandle)
    }

    static func terminate(_ pid: pid_t, waitSeconds: TimeInterval = 5) {
        guard pid > 0 else { return }
        let children = descendantPids(of: pid)
        blast(pid, children: children, signal: SIGTERM)

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            if waitNonBlocking(pid) {
                blast(pid, children: children, signal: SIGKILL)
                return
            }
            usleep(100_000)
        }

        blast(pid, children: children, signal: SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline {
            if waitNonBlocking(pid) {
                return
            }
            usleep(50_000)
        }
        _ = waitpid(pid, nil, 0)
    }

    static func killImmediately(_ pid: pid_t) {
        guard pid > 0 else { return }
        let children = descendantPids(of: pid)
        blast(pid, children: children, signal: SIGKILL)
        _ = waitpid(pid, nil, 0)
    }

    private static func blast(_ root: pid_t, children: [pid_t], signal: Int32) {
        _ = kill(-root, signal)
        _ = kill(root, signal)
        for child in children.reversed() {
            _ = kill(-child, signal)
            _ = kill(child, signal)
        }
    }

    private static func descendantPids(of root: pid_t) -> [pid_t] {
        var ordered: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var queue: [pid_t] = [root]
        while let current = queue.first {
            queue.removeFirst()
            var buffer = [pid_t](repeating: 0, count: 256)
            let filled = buffer.withUnsafeMutableBufferPointer { pointer in
                proc_listchildpids(
                    current,
                    pointer.baseAddress,
                    Int32(pointer.count * MemoryLayout<pid_t>.size)
                )
            }
            let count = max(0, Int(filled))
            let pidCount = count > buffer.count ? count / MemoryLayout<pid_t>.size : count
            for index in 0..<min(pidCount, buffer.count) {
                let child = buffer[index]
                if child > 0, seen.insert(child).inserted {
                    ordered.append(child)
                    queue.append(child)
                }
            }
        }
        return ordered
    }

    @discardableResult
    static func waitNonBlocking(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) rethrows -> T {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
