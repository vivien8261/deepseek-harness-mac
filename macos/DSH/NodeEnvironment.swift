import Darwin
import Foundation

struct BundledRuntime {
    let nodeExecutable: String
    let binScript: String
    let dshRoot: String
    let nodeBinDir: String
    let version: String
    let commit: String
    let nodeVersion: String
}

enum NodeEnvironment {
    static let defaultPort = 3080
    static let portRange = 3080...3180

    /// Runtime staged into Contents/Resources by macos/scripts/stage-runtime.sh.
    static func bundledRuntime() -> BundledRuntime? {
        guard let resources = Bundle.main.resourcePath else { return nil }
        let node = resources + "/node/bin/node"
        let bin = resources + "/dsh/lib/bin.js"
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: node),
              fileManager.fileExists(atPath: bin)
        else {
            return nil
        }

        var version = "unknown"
        var commit = "unknown"
        var nodeVersion = "unknown"
        let manifestURL = URL(fileURLWithPath: resources + "/runtime.json")
        if let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            version = json["version"] as? String ?? version
            commit = json["commit"] as? String ?? commit
            nodeVersion = json["node"] as? String ?? nodeVersion
        }

        return BundledRuntime(
            nodeExecutable: node,
            binScript: bin,
            dshRoot: resources + "/dsh",
            nodeBinDir: (node as NSString).deletingLastPathComponent,
            version: version,
            commit: commit,
            nodeVersion: nodeVersion
        )
    }

    static func webArguments(port: Int, binScript: String) -> [String] {
        [binScript, "web", "--host", "127.0.0.1", "--port", String(port), "--no-open"]
    }

    static func launchEnvironment(nodeBinDir: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CI"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["TERM"] = environment["TERM"] ?? "dumb"
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = nodeBinDir + ":" + path
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
