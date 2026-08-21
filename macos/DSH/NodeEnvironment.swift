import Darwin
import Foundation

enum NodeEnvironment {
    static let defaultPort = 3080
    static let portRange = 3080...3180

    /// Project root, derived from the app bundle location:
    /// <repo>/dist/DeepSeek Harness.app -> <repo>/dist -> <repo>
    static func repoRoot() -> String? {
        let bundle = Bundle.main.bundlePath
        let dist = (bundle as NSString).deletingLastPathComponent
        let repo = (dist as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repo + "/macos/build.sh"),
              fileManager.fileExists(atPath: repo + "/deepseek-harness/.git")
        else {
            return nil
        }
        return repo
    }

    static func command(port: Int, repoRoot: String) -> String {
        let repo = shellQuote(repoRoot)
        let dsh = "\(repo)/deepseek-harness"
        let bin = "\(dsh)/apps/cli/lib/bin.js"
        let buildScript = "\(repo)/macos/scripts/build-dsh.sh"
        return """
        repo=\(repo)
        dsh=\(dsh)
        bin=\(bin)
        for cand in /opt/homebrew/opt/node@24/bin /usr/local/opt/node@24/bin; do
          [ -x "$cand/node" ] && export PATH="$cand:$PATH" && break
        done
        echo "dsh: 源码目录: $dsh" >&2
        echo "dsh: 当前 commit: $(git -C "$dsh" rev-parse HEAD 2>/dev/null || echo unknown)" >&2
        echo "dsh: node: $(node -v 2>/dev/null || echo missing)" >&2
        if [ ! -f "$bin" ]; then
          echo "dsh: 未找到构建产物 $bin" >&2
          echo "dsh: 正在从源码构建（首次运行或源码已更新，请耐心等待，日志见下）…" >&2
          \(buildScript) "$repo" || { echo "dsh: 构建失败，请查看上方日志" >&2; exit 1; }
        else
          echo "dsh: 产物已存在，校验构建缓存…" >&2
          \(buildScript) "$repo" || { echo "dsh: 构建失败，请查看上方日志" >&2; exit 1; }
          echo "dsh: 复用已构建产物（缓存命中）" >&2
        fi
        ver="$(node -p "require('$dsh/apps/cli/package.json').version" 2>/dev/null || echo unknown)"
        echo "dsh: version $ver" >&2
        echo "dsh: launching $bin" >&2
        exec node "$bin" web --host 127.0.0.1 --port \(port)
        """
    }

    /// Quote a path for safe embedding into the /bin/zsh command string.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CI"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = environment["TERM"] ?? "dumb"
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return environment
    }

    static func firstFreePort(in range: ClosedRange<Int> = portRange) -> Int? {
        for port in range where isPortFree(port) {
            return port
        }
        return nil
    }

    static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
