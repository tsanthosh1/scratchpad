import Foundation

struct JDK: Equatable {
    let home: String
    let version: String
    let name: String

    var majorVersion: Int {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let first = parts.first else { return 0 }
        return first == 1 && parts.count > 1 ? parts[1] : first
    }
}

enum Toolchains {
    // MARK: Java

    static func installedJDKs() -> [JDK] {
        guard let data = runCapture("/usr/libexec/java_home", ["-X"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        return plist.compactMap { entry in
            guard let home = entry["JVMHomePath"] as? String else { return nil }
            return JDK(home: home,
                       version: entry["JVMVersion"] as? String ?? "?",
                       name: entry["JVMName"] as? String ?? (home as NSString).lastPathComponent)
        }
    }

    /// The JDK used to run Java scratches: an explicit home from settings, otherwise the newest
    /// installed JDK matching the preferred major version, otherwise the newest JDK overall.
    static func resolveJDK() -> JDK? {
        let jdks = installedJDKs()
        let custom = Settings.shared.javaHome
        if !custom.isEmpty {
            if let match = jdks.first(where: { $0.home == custom }) { return match }
            if FileManager.default.isExecutableFile(atPath: custom + "/bin/java") {
                return JDK(home: custom, version: "?", name: (custom as NSString).lastPathComponent)
            }
        }
        let wanted = Settings.shared.javaVersion
        return jdks.first(where: { $0.majorVersion == wanted }) ?? jdks.first
    }

    // MARK: Node, Python & other tools

    private static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    /// GUI apps don't inherit the shell PATH (fnm/nvm/volta/pyenv live there), so ask a login shell
    /// once per tool and fall back to well-known install locations.
    static func resolveNode() -> String? {
        let custom = Settings.shared.nodePath
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) { return custom }
        return resolveTool("node", fallbacks: knownNodeLocations)
    }

    static func resolvePython() -> String? {
        resolveTool("python3", fallbacks: { ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] })
    }

    static func invalidateNodeCache() {
        cacheLock.lock()
        cache.removeValue(forKey: "node")
        cacheLock.unlock()
    }

    private static func resolveTool(_ name: String, fallbacks: () -> [String]) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[name] { return cached }
        let found = probeShell(for: name)
            ?? fallbacks().first { FileManager.default.isExecutableFile(atPath: $0) }
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        cache[name] = .some(found)
        return found
    }

    private static func probeShell(for tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let data = runCapture(shell, ["-ilc", "command -v \(tool)"], timeout: 5),
              let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n").reversed() {
            let path = line.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
                // fnm hands out per-shell symlinks that disappear later; keep the real binary.
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
        }
        return nil
    }

    private static func knownNodeLocations() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.local/share/fnm/aliases/default/bin/node",
        ]
        for versionsDir in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions"] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir)) ?? []
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(versionsDir)/\(v)/bin/node")
                candidates.append("\(versionsDir)/\(v)/installation/bin/node")
            }
        }
        return candidates
    }

    // MARK: Helpers

    static func runCapture(_ executable: String, _ args: [String], timeout: TimeInterval = 10) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
