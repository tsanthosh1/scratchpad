import Foundation
import JavaScriptCore

enum OutputKind {
    case stdout, stderr, info
}

protocol RunnerDelegate: AnyObject {
    func runner(_ runner: Runner, output: String, kind: OutputKind)
    func runnerDidFinish(_ runner: Runner, exitCode: Int32, elapsed: TimeInterval)
}

/// Runs a scratch in a throwaway directory. Java uses single-file source launch (`java Foo.java`),
/// JavaScript uses Node when available and falls back to the built-in JavaScriptCore.
final class Runner {
    weak var delegate: RunnerDelegate?
    private var process: Process?
    private var started = Date()
    private var killTimer: DispatchWorkItem?

    var isRunning: Bool { process?.isRunning ?? false }

    func run(language: Language, source: String) {
        stop()
        let dir = AppPaths.runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fail("Could not create run directory: \(error.localizedDescription)")
            return
        }
        cleanupOldRuns(keeping: dir)

        switch language {
        case .java: runJava(source: source, in: dir)
        case .javascript: runJavaScript(source: source, in: dir)
        case .typescript: runTypeScript(source: source, in: dir)
        case .python: runPython(source: source, in: dir)
        case .shell: runScript(interpreter: "/bin/bash", fileName: "scratch.sh", source: source, in: dir, label: "bash")
        default: fail("\(language.displayName) scratches can't be run.")
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        emit("Stopping…\n", .info)
        process.terminate()
        let pid = process.processIdentifier
        let timer = DispatchWorkItem { if process.isRunning { kill(pid, SIGKILL) } }
        killTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timer)
    }

    // MARK: Java

    private func runJava(source: String, in dir: URL) {
        guard let jdk = Toolchains.resolveJDK() else {
            fail("No JDK found. Install one or set the JDK in Settings (⌘,).")
            return
        }
        if jdk.majorVersion != 0 && jdk.majorVersion < 11 {
            fail("\(jdk.name) is Java \(jdk.majorVersion); running a single source file needs Java 11 or newer. Pick another JDK in Settings (⌘,).")
            return
        }
        let className = Self.javaClassName(in: source) ?? "Main"
        let file = dir.appendingPathComponent("\(className).java")
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not write source: \(error.localizedDescription)")
            return
        }
        let java = jdk.home + "/bin/java"
        emit("\(jdk.name) (\(jdk.version))\n$ java \(file.lastPathComponent)\n", .info)
        var env = ProcessInfo.processInfo.environment
        env["JAVA_HOME"] = jdk.home
        launch(java, ["-Dfile.encoding=UTF-8", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8", file.lastPathComponent],
               in: dir, env: env)
    }

    static func javaClassName(in source: String) -> String? {
        let pattern = #"(?m)^\s*public\s+(?:(?:final|abstract|sealed|strictfp)\s+)*(?:class|record|interface|enum)\s+([A-Za-z_$][\w$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    // MARK: JavaScript

    private func runJavaScript(source: String, in dir: URL) {
        guard let node = Toolchains.resolveNode() else {
            runWithJavaScriptCore(source)
            return
        }
        let file = dir.appendingPathComponent("scratch.js")
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not write source: \(error.localizedDescription)")
            return
        }
        let version = nodeVersion(node)
        linkSharedModules(into: dir)
        emit("Node \(version)\n$ node scratch.js\n", .info)
        var env = ProcessInfo.processInfo.environment
        let nodeDir = (node as NSString).deletingLastPathComponent
        env["PATH"] = "\(nodeDir):" + (env["PATH"] ?? "/usr/bin:/bin")
        env["FORCE_COLOR"] = "0"
        let major = Int(version.dropFirst().split(separator: ".").first ?? "") ?? 0
        let flags = major >= 22 ? [Self.quietModuleTypeWarning] : []
        launch(node, flags + [file.lastPathComponent], in: dir, env: env)
    }

    private func runTypeScript(source: String, in dir: URL) {
        guard let node = Toolchains.resolveNode() else {
            fail("TypeScript scratches need Node.js 22.6 or newer. Set the Node path in Settings (⌘,).")
            return
        }
        let version = nodeVersion(node)
        let major = Int(version.dropFirst().split(separator: ".").first ?? "") ?? 0
        let minor = Int(version.split(separator: ".").dropFirst().first ?? "") ?? 0
        if major < 22 || (major == 22 && minor < 6) {
            fail("Node \(version) can't run TypeScript directly; Node 22.6+ is needed (type stripping).")
            return
        }
        // Type stripping is on by default from Node 23.6; older 22.x needs the flag.
        let flags = major >= 23 && (major > 23 || minor >= 6) ? [] : ["--experimental-strip-types"]
        linkSharedModules(into: dir)
        runScript(interpreter: node, fileName: "scratch.ts", source: source, in: dir,
                  label: "Node \(version)",
                  extraArgs: flags + ["--disable-warning=ExperimentalWarning", Self.quietModuleTypeWarning])
    }

    private func runPython(source: String, in dir: URL) {
        guard let python = Toolchains.resolvePython() else {
            fail("python3 not found. Install Python 3 (e.g. `brew install python`).")
            return
        }
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        runScript(interpreter: python, fileName: "scratch.py", source: source, in: dir, label: "python3", env: env)
    }

    /// Writes `source` to `fileName` and runs `interpreter [extraArgs] fileName`.
    private func runScript(interpreter: String, fileName: String, source: String, in dir: URL, label: String,
                           extraArgs: [String] = [], env: [String: String]? = nil) {
        let file = dir.appendingPathComponent(fileName)
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            fail("Could not write source: \(error.localizedDescription)")
            return
        }
        emit("\(label)\n$ \((interpreter as NSString).lastPathComponent) \(fileName)\n", .info)
        var environment = env ?? ProcessInfo.processInfo.environment
        let binDir = (interpreter as NSString).deletingLastPathComponent
        environment["PATH"] = "\(binDir):" + (environment["PATH"] ?? "/usr/bin:/bin")
        launch(interpreter, extraArgs + [fileName], in: dir, env: environment)
    }

    /// Runs live under the home folder, so a shared ~/package.json without "type" makes Node warn on every
    /// ES module scratch.
    private static let quietModuleTypeWarning = "--disable-warning=MODULE_TYPELESS_PACKAGE_JSON"

    /// Node resolves packages (for both `require` and `import`) by walking up from the script, so a
    /// `node_modules` link next to it exposes the shared pool without touching NODE_PATH.
    private func linkSharedModules(into dir: URL) {
        let modules = SharedPackages.modules
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modules.path, isDirectory: &isDir), isDir.boolValue else { return }
        do {
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("node_modules"),
                                                       withDestinationURL: modules)
            emit("Shared packages: \((modules.path as NSString).abbreviatingWithTildeInPath)\n", .info)
        } catch {
            emit("Could not link shared packages: \(error.localizedDescription)\n", .info)
        }
    }

    /// `npm install` in the shared packages folder, streamed to the console like a run.
    func installSharedPackages() {
        stop()
        guard let node = Toolchains.resolveNode() else {
            fail("npm needs Node.js. Set the Node path in Settings (⌘,).")
            return
        }
        let binDir = (node as NSString).deletingLastPathComponent
        let npm = binDir + "/npm"
        guard FileManager.default.isExecutableFile(atPath: npm) else {
            fail("npm not found next to \(node).")
            return
        }
        do {
            try SharedPackages.ensureManifest()
        } catch {
            fail("Could not create package.json: \(error.localizedDescription)")
            return
        }
        let folder = SharedPackages.folder
        emit("Node \(nodeVersion(node))\n$ cd \((folder.path as NSString).abbreviatingWithTildeInPath)\n$ npm install\n", .info)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(binDir):" + (env["PATH"] ?? "/usr/bin:/bin")
        env["NO_COLOR"] = "1"
        env["npm_config_fund"] = "false"
        env["npm_config_update_notifier"] = "false"
        launch(npm, ["install"], in: folder, env: env)
    }

    private func nodeVersion(_ node: String) -> String {
        Toolchains.runCapture(node, ["--version"]).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func runWithJavaScriptCore(_ source: String) {
        emit("Node.js not found, using the built-in JavaScriptCore (no require/fs/timers). Set the Node path in Settings (⌘,).\n", .info)
        started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let context = JSContext()!
            let log: @convention(block) () -> Void = {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let line = args.map { Self.describe($0) }.joined(separator: " ") + "\n"
                DispatchQueue.main.async { self.emit(line, .stdout) }
            }
            let error: @convention(block) () -> Void = {
                let args = JSContext.currentArguments() as? [JSValue] ?? []
                let line = args.map { Self.describe($0) }.joined(separator: " ") + "\n"
                DispatchQueue.main.async { self.emit(line, .stderr) }
            }
            let console = JSValue(newObjectIn: context)!
            for name in ["log", "info", "debug"] { console.setObject(log, forKeyedSubscript: name as NSString) }
            for name in ["error", "warn"] { console.setObject(error, forKeyedSubscript: name as NSString) }
            context.setObject(console, forKeyedSubscript: "console" as NSString)

            var exitCode: Int32 = 0
            context.exceptionHandler = { _, exception in
                exitCode = 1
                let msg = exception?.toString() ?? "Unknown error"
                let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
                DispatchQueue.main.async { self.emit("\(msg) (line \(line))\n", .stderr) }
            }
            context.evaluateScript(source)
            DispatchQueue.main.async {
                self.delegate?.runnerDidFinish(self, exitCode: exitCode, elapsed: Date().timeIntervalSince(self.started))
            }
        }
    }

    private static func describe(_ value: JSValue) -> String {
        if value.isString { return value.toString() }
        if value.isObject,
           let json = value.context.objectForKeyedSubscript("JSON")?
            .invokeMethod("stringify", withArguments: [value, JSValue(nullIn: value.context)!, 2]),
           json.isString {
            return json.toString()
        }
        return value.toString()
    }

    // MARK: Process plumbing

    private func launch(_ executable: String, _ args: [String], in dir: URL, env: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outDecoder = StreamDecoder(), errDecoder = StreamDecoder()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = outDecoder.decode(h.availableData)
            if !text.isEmpty { DispatchQueue.main.async { self?.emit(text, .stdout) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = errDecoder.decode(h.availableData)
            if !text.isEmpty { DispatchQueue.main.async { self?.emit(text, .stderr) } }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = outDecoder.decode(out.fileHandleForReading.readDataToEndOfFile(), final: true)
            let restErr = errDecoder.decode(err.fileHandleForReading.readDataToEndOfFile(), final: true)
            DispatchQueue.main.async {
                guard let self else { return }
                if !restOut.isEmpty { self.emit(restOut, .stdout) }
                if !restErr.isEmpty { self.emit(restErr, .stderr) }
                self.killTimer?.cancel()
                if self.process === p { self.process = nil }
                self.delegate?.runnerDidFinish(self, exitCode: p.terminationStatus,
                                               elapsed: Date().timeIntervalSince(self.started))
            }
        }

        do {
            started = Date()
            try process.run()
            self.process = process
        } catch {
            fail("Failed to start \(executable): \(error.localizedDescription)")
        }
    }

    private func emit(_ text: String, _ kind: OutputKind) {
        delegate?.runner(self, output: text, kind: kind)
    }

    private func fail(_ message: String) {
        emit(message + "\n", .stderr)
        delegate?.runnerDidFinish(self, exitCode: -1, elapsed: 0)
    }

    private func cleanupOldRuns(keeping current: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let entries = (try? fm.contentsOfDirectory(at: AppPaths.runs, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in entries where url != current {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: url) }
        }
    }
}

/// Decodes UTF-8 across chunk boundaries so multi-byte characters split between reads survive.
private final class StreamDecoder {
    private var buffer = Data()
    private let lock = NSLock()

    func decode(_ chunk: Data, final: Bool = false) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        for trim in 0...min(3, buffer.count) {
            let candidate = buffer.prefix(buffer.count - trim)
            if let s = String(data: candidate, encoding: .utf8) {
                buffer = Data(buffer.suffix(trim))
                if final && !buffer.isEmpty {
                    let rest = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return s + rest
                }
                return s
            }
        }
        let s = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return s
    }
}
