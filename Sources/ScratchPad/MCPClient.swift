import Foundation
import AppKit

enum MCPTransportType: String, CaseIterable {
    case stdio = "stdio"
    case sse = "sse"

    var title: String {
        switch self {
        case .stdio: return "Stdio (Command)"
        case .sse: return "SSE / HTTP (URL)"
        }
    }
}

struct MCPConfig: Equatable {
    var name: String = "mcp-remote"
    var transport: MCPTransportType = .stdio
    var command: String = "npx"
    var args: [String] = ["-y", "mcp-remote", "http://localhost:8000/sse"]
    var env: [String: String] = [:]
    var url: String = "http://localhost:8000/sse"
    var headers: [String: String] = [:]

    var commandLineString: String {
        let parts = [command] + args
        return parts.map { arg in
            if arg.isEmpty { return "\"\"" }
            if arg.contains(" ") || arg.contains("\"") {
                return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return arg
        }.joined(separator: " ")
    }

    var formattedArgs: String {
        return args.map { arg in
            if arg.isEmpty { return "\"\"" }
            if arg.contains(" ") || arg.contains("\"") {
                return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return arg
        }.joined(separator: " ")
    }

    var envString: String {
        env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
    }

    var headersString: String {
        headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
    }

    static func normalizeHeaderArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if (arg == "--header" || arg == "-H"), i + 1 < args.count {
                let firstVal = args[i + 1]
                if firstVal.hasSuffix(":") || (!firstVal.contains(":") && !firstVal.hasPrefix("-") && i + 2 < args.count && !args[i + 2].hasPrefix("-")) {
                    let headerName = firstVal.hasSuffix(":") ? String(firstVal.dropLast()) : firstVal
                    var headerParts: [String] = []
                    var j = i + 2
                    while j < args.count && !args[j].hasPrefix("-") {
                        headerParts.append(args[j])
                        j += 1
                    }
                    if !headerParts.isEmpty {
                        result.append(arg)
                        result.append("\(headerName): \(headerParts.joined(separator: " "))")
                        i = j
                        continue
                    }
                } else if firstVal.contains(":") {
                    result.append(arg)
                    result.append(firstVal)
                    i += 2
                    continue
                }
            }
            result.append(arg)
            i += 1
        }
        return result
    }

    static func parseCommandLine(_ line: String) -> (command: String, args: [String], env: [String: String]) {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaping = false

        for ch in line {
            if escaping {
                current.append(ch)
                escaping = false
            } else if ch == "\\" && !inSingle {
                escaping = true
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        var env: [String: String] = [:]
        var cmdTokens: [String] = []
        var parsingEnv = true
        for token in tokens {
            if parsingEnv, let eq = token.firstIndex(of: "="), eq != token.startIndex {
                let k = String(token[..<eq])
                let v = String(token[token.index(after: eq)...])
                env[k] = v
            } else {
                parsingEnv = false
                cmdTokens.append(token)
            }
        }

        guard let cmd = cmdTokens.first,
              !cmd.hasPrefix("{"), !cmd.hasPrefix("}"), !cmd.hasPrefix("["), !cmd.hasPrefix("]") else {
            return ("", [], env)
        }
        return (cmd, normalizeHeaderArgs(Array(cmdTokens.dropFirst())), env)
    }

    static func parseEnvString(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let items = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if let eq = trimmed.firstIndex(of: "=") {
                let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { result[k] = v }
            }
        }
        return result
    }

    static func parseHeadersString(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let items = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":") {
                let k = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { result[k] = v }
            }
        }
        return result
    }

    static func sanitizeJSON(_ text: String) -> String {
        var result = ""
        var inString = false
        var escaping = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if inString {
                result.append(ch)
                if escaping {
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else if ch == "\"" {
                    inString = false
                }
                i += 1
            } else {
                if ch == "\"" {
                    inString = true
                    result.append(ch)
                    i += 1
                } else if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    // Line comment: skip until newline
                    i += 2
                    while i < chars.count && chars[i] != "\n" && chars[i] != "\r" {
                        i += 1
                    }
                } else if ch == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    // Block comment: skip until */
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i += 2 // skip */
                } else {
                    result.append(ch)
                    i += 1
                }
            }
        }

        // Remove trailing commas before } or ]
        result = result.replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
        return result
    }

    static func parse(from text: String) -> MCPConfig? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip enclosing quotes if user pasted a quoted string like "npx -y mcp-remote"
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        // 1. If it starts with { or [, treat it STRICTLY as JSON.
        // It must NEVER fall through to shell command line parsing!
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let cleaned = sanitizeJSON(trimmed)
            if let data = cleaned.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                if let obj = json as? [String: Any] {
                    // Check "mcpServers"
                    if let servers = obj["mcpServers"] as? [String: Any] {
                        for (k, v) in servers {
                            if let srvDict = v as? [String: Any] {
                                return parseServerDict(srvDict, name: k)
                            }
                        }
                    }
                    // Check "servers" (Zed / Cursor / VS Code format)
                    if let servers = obj["servers"] as? [String: Any] {
                        for (k, v) in servers {
                            if let srvDict = v as? [String: Any] {
                                return parseServerDict(srvDict, name: k)
                            }
                        }
                    }
                    // Direct server object with command or url
                    if obj["command"] != nil || obj["url"] != nil {
                        return parseServerDict(obj, name: "server")
                    }
                    // Wrapped in single server name: e.g. { "mcp-remote": { "command": "npx", ... } }
                    if obj.count == 1, let (k, v) = obj.first, let srvDict = v as? [String: Any],
                       srvDict["command"] != nil || srvDict["url"] != nil {
                        return parseServerDict(srvDict, name: k)
                    }
                } else if let arr = json as? [[String: Any]], let first = arr.first {
                    let name = (first["name"] as? String) ?? "server"
                    return parseServerDict(first, name: name)
                }
            }
            // Starts with { or [, but wasn't valid or recognized JSON.
            // DO NOT fall through to shell command parser. Return nil!
            return nil
        }

        // 2. Try parsing as direct HTTP/HTTPS URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            var name = "remote-server"
            if let u = URL(string: trimmed), let host = u.host {
                name = host
            }
            return MCPConfig(name: name, transport: .sse, url: trimmed)
        }

        // 3. Try parsing as shell command line
        let (cmd, args, env) = parseCommandLine(trimmed)
        if !cmd.isEmpty, !cmd.hasPrefix("{"), !cmd.hasPrefix("}"), !cmd.hasPrefix("["), !cmd.hasPrefix("]") {
            var name = cmd
            if name == "npx" || name == "uvx" || name == "node" || name == "python3" || name == "python" {
                if let target = args.first(where: { !$0.hasPrefix("-") }) {
                    name = (target as NSString).lastPathComponent
                }
            }
            return MCPConfig(name: name, transport: .stdio, command: cmd, args: normalizeHeaderArgs(args), env: env)
        }

        return nil
    }

    private static func parseServerDict(_ srv: [String: Any], name: String) -> MCPConfig {
        let isSSE = (srv["transport"] as? String) == "sse" || (srv["type"] as? String) == "sse" || srv["url"] != nil
        if isSSE, let url = srv["url"] as? String {
            var headers: [String: String] = [:]
            if let h = srv["headers"] as? [String: String] { headers = h }
            return MCPConfig(name: name, transport: .sse, url: url, headers: headers)
        }
        let cmd = (srv["command"] as? String) ?? "npx"
        var args: [String] = []
        if let rawArgs = srv["args"] as? [Any] {
            args = rawArgs.map { "\($0)" }
        }
        args = normalizeHeaderArgs(args)
        var env: [String: String] = [:]
        if let e = srv["env"] as? [String: Any] {
            for (k, v) in e { env[k] = "\(v)" }
        }
        return MCPConfig(name: name, transport: .stdio, command: cmd, args: args, env: env)
    }

    func toJSONString() -> String {
        var serverDict: [String: Any] = [:]
        if transport == .stdio {
            serverDict["command"] = command
            serverDict["args"] = args
            if !env.isEmpty {
                serverDict["env"] = env
            }
        } else {
            serverDict["url"] = url
            if !headers.isEmpty {
                serverDict["headers"] = headers
            }
        }
        let root: [String: Any] = [
            "mcpServers": [
                name.isEmpty ? "server" : name: serverDict
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }
}

struct MCPTool: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String?
    let inputSchema: [String: Any]

    var parametersDescription: String {
        guard let props = inputSchema["properties"] as? [String: [String: Any]] else {
            return "No parameters required"
        }
        let required = Set((inputSchema["required"] as? [String]) ?? [])
        if props.isEmpty { return "No parameters required" }
        return props.map { key, schema in
            let type = (schema["type"] as? String) ?? "any"
            let req = required.contains(key) ? "required" : "optional"
            let desc = (schema["description"] as? String).map { " — \($0)" } ?? ""
            return "• \(key) (\(type), \(req))\(desc)"
        }.sorted().joined(separator: "\n")
    }

    func sampleArgumentsJSON() -> String {
        guard let props = inputSchema["properties"] as? [String: [String: Any]] else {
            return "{}"
        }
        var sample: [String: Any] = [:]
        for (key, schema) in props {
            let type = (schema["type"] as? String) ?? "string"
            switch type {
            case "string":
                sample[key] = (schema["description"] as? String) ?? "value"
            case "number", "integer":
                sample[key] = 0
            case "boolean":
                sample[key] = false
            case "array":
                sample[key] = []
            case "object":
                sample[key] = [:]
            default:
                sample[key] = ""
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    static func == (lhs: MCPTool, rhs: MCPTool) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
    }
}

struct MCPPrompt: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String?
}

struct MCPResource: Identifiable, Equatable {
    var id: String { uri }
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

enum MCPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(serverName: String, version: String, protocolVersion: String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Manages MCP (Model Context Protocol) JSON-RPC client communication over Stdio and SSE/HTTP.
final class MCPClient: NSObject, URLSessionDataDelegate {
    var onStateChange: ((MCPConnectionState) -> Void)?
    var onLog: ((String, OutputKind) -> Void)?
    var onToolsReceived: (([MCPTool]) -> Void)?
    var onPromptsReceived: (([MCPPrompt]) -> Void)?
    var onResourcesReceived: (([MCPResource]) -> Void)?

    private let lock = NSLock()
    private var _state: MCPConnectionState = .disconnected
    var state: MCPConnectionState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _state
        }
        set {
            lock.lock()
            _state = newValue
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChange?(newValue)
            }
        }
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    private var nextRequestId: Int = 1
    private var pendingHandlers: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var currentConfig: MCPConfig?
    private var lastStderrLine = ""

    // SSE support
    private var sseSession: URLSession?
    private var sseTask: URLSessionDataTask?
    private var sseEndpointURL: URL?
    private var sseBuffer = ""

    func connect(config: MCPConfig) {
        disconnect()
        currentConfig = config
        state = .connecting
        log("[info] Connecting to \(config.name) via \(config.transport.title)…", .info)

        if config.transport == .stdio {
            connectStdio(config: config)
        } else {
            connectSSE(config: config)
        }
    }

    func disconnect() {
        lock.lock()
        let proc = process
        process = nil
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        stdoutBuffer = ""
        stderrBuffer = ""
        lastStderrLine = ""
        pendingHandlers.removeAll()

        sseTask?.cancel()
        sseTask = nil
        sseSession?.invalidateAndCancel()
        sseSession = nil
        sseEndpointURL = nil
        sseBuffer = ""
        lock.unlock()

        if let proc, proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }

        if state != .disconnected {
            log("[info] Disconnected.", .info)
            state = .disconnected
        }
    }

    // MARK: - Stdio Transport

    private func connectStdio(config: MCPConfig) {
        let p = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        stdinPipe = inPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe

        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Execute through login zsh so user PATH (node/npm/python/uvx/brew) is fully resolved
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "exec \"$@\"", "--", config.command] + config.args

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin",
            "\(home)/.nvm/versions/node", "\(home)/.volta/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        for (k, v) in config.env { env[k] = v }
        p.environment = env

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.receiveStdoutData(data)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.receiveStderrData(data)
        }

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let code = proc.terminationStatus
            self.lock.lock()
            let isCurrent = self.process === proc
            let pending = self.pendingHandlers
            self.pendingHandlers.removeAll()
            let errText = self.lastStderrLine
            self.lock.unlock()

            if isCurrent {
                DispatchQueue.main.async {
                    if self.state != .disconnected {
                        self.log("[info] Process exited with status \(code)", code == 0 ? .info : .stderr)
                        let message = errText.isEmpty ? "Process exited with status \(code)" : errText
                        if case .connecting = self.state {
                            self.state = .error("Process exited early (exit \(code)): \(message)")
                        } else {
                            self.state = .disconnected
                        }
                    }
                    for (_, handler) in pending {
                        handler(.failure(NSError(domain: "MCP", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Process exited with status \(code): \(errText)"])))
                    }
                }
            }
        }

        do {
            try p.run()
            self.process = p
            startInitializeHandshake()
        } catch {
            log("[error] Failed to launch process: \(error.localizedDescription)", .stderr)
            state = .error("Failed to launch: \(error.localizedDescription)")
        }
    }

    private func receiveStdoutData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        lock.lock()
        stdoutBuffer += text
        var lines: [String] = []
        while let nl = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<nl.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(..<nl.upperBound)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()

        for line in lines {
            handleIncomingJSONRPC(line)
        }
    }

    private func receiveStderrData(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        lock.lock()
        stderrBuffer += text
        var lines: [String] = []
        while let nl = stderrBuffer.range(of: "\n") {
            let line = String(stderrBuffer[..<nl.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            stderrBuffer.removeSubrange(..<nl.upperBound)
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()

        for line in lines {
            lock.lock()
            lastStderrLine = line
            lock.unlock()
            log("[stderr] \(line)", .stderr)
        }
    }

    // MARK: - SSE / HTTP Transport

    private func connectSSE(config: MCPConfig) {
        guard let endpoint = URL(string: config.url) else {
            state = .error("Invalid server URL: \(config.url)")
            return
        }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 30
        for (k, v) in config.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.sseSession = session
        let task = session.dataTask(with: req)
        self.sseTask = task
        task.resume()

        // Also test direct HTTP initialize in case endpoint is a simple HTTP JSON-RPC endpoint
        startInitializeHandshake()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        sseBuffer += text
        var events: [String] = []
        while let doubleNl = sseBuffer.range(of: "\n\n") {
            let event = String(sseBuffer[..<doubleNl.lowerBound])
            sseBuffer.removeSubrange(..<doubleNl.upperBound)
            events.append(event)
        }
        lock.unlock()

        for event in events {
            handleSSEEvent(event)
        }
    }

    private func handleSSEEvent(_ event: String) {
        var eventType = "message"
        var eventData = ""
        for line in event.split(separator: "\n") {
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                eventData += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }

        if eventType == "endpoint", let urlStr = currentConfig?.url, let baseURL = URL(string: urlStr) {
            let resolved = URL(string: eventData, relativeTo: baseURL)?.absoluteURL
            self.sseEndpointURL = resolved
            log("[info] SSE endpoint resolved: \(resolved?.absoluteString ?? eventData)", .info)
            startInitializeHandshake()
        } else if !eventData.isEmpty {
            handleIncomingJSONRPC(eventData)
        }
    }

    // MARK: - Protocol & Requests

    private func startInitializeHandshake() {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "roots": ["listChanged": true],
                "sampling": [:] as [String: Any]
            ],
            "clientInfo": [
                "name": "ScratchPad MCP Tester",
                "version": "1.0.0"
            ]
        ]

        sendRequest(method: "initialize", params: params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                let serverInfo = res["serverInfo"] as? [String: Any]
                let name = (serverInfo?["name"] as? String) ?? (self.currentConfig?.name ?? "MCP Server")
                let ver = (serverInfo?["version"] as? String) ?? "1.0.0"
                let proto = (res["protocolVersion"] as? String) ?? "2024-11-05"

                self.log("[info] Handshake successful! Server: \(name) v\(ver) (Protocol \(proto))", .info)

                // Send initialized notification
                self.sendNotification(method: "notifications/initialized")

                self.state = .connected(serverName: name, version: ver, protocolVersion: proto)

                // Automatically query tools
                self.listTools()

            case .failure(let err):
                self.log("[error] Initialize failed: \(err.localizedDescription)", .stderr)
                self.state = .error("Initialize failed: \(err.localizedDescription)")
            }
        }
    }

    func listTools(completion: (([MCPTool]?, Error?) -> Void)? = nil) {
        sendRequest(method: "tools/list", params: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                var tools: [MCPTool] = []
                if let rawTools = res["tools"] as? [[String: Any]] {
                    for item in rawTools {
                        if let name = item["name"] as? String {
                            let desc = item["description"] as? String
                            let schema = (item["inputSchema"] as? [String: Any]) ?? [:]
                            tools.append(MCPTool(name: name, description: desc, inputSchema: schema))
                        }
                    }
                }
                self.log("[info] Received \(tools.count) tool\(tools.count == 1 ? "" : "s") from server.", .info)
                self.onToolsReceived?(tools)
                completion?(tools, nil)
            case .failure(let err):
                self.log("[error] tools/list error: \(err.localizedDescription)", .stderr)
                completion?(nil, err)
            }
        }
    }

    func listPrompts(completion: (([MCPPrompt]?, Error?) -> Void)? = nil) {
        sendRequest(method: "prompts/list", params: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                var prompts: [MCPPrompt] = []
                if let rawPrompts = res["prompts"] as? [[String: Any]] {
                    for item in rawPrompts {
                        if let name = item["name"] as? String {
                            prompts.append(MCPPrompt(name: name, description: item["description"] as? String))
                        }
                    }
                }
                self.log("[info] Received \(prompts.count) prompt\(prompts.count == 1 ? "" : "s")", .info)
                self.onPromptsReceived?(prompts)
                completion?(prompts, nil)
            case .failure(let err):
                self.log("[error] prompts/list error: \(err.localizedDescription)", .stderr)
                completion?(nil, err)
            }
        }
    }

    func listResources(completion: (([MCPResource]?, Error?) -> Void)? = nil) {
        sendRequest(method: "resources/list", params: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                var resources: [MCPResource] = []
                if let raw = res["resources"] as? [[String: Any]] {
                    for item in raw {
                        if let uri = item["uri"] as? String, let name = item["name"] as? String {
                            resources.append(MCPResource(uri: uri, name: name,
                                                         description: item["description"] as? String,
                                                         mimeType: item["mimeType"] as? String))
                        }
                    }
                }
                self.log("[info] Received \(resources.count) resource\(resources.count == 1 ? "" : "s")", .info)
                self.onResourcesReceived?(resources)
                completion?(resources, nil)
            case .failure(let err):
                self.log("[error] resources/list error: \(err.localizedDescription)", .stderr)
                completion?(nil, err)
            }
        }
    }

    func ping(completion: ((Bool, TimeInterval) -> Void)? = nil) {
        let start = Date()
        sendRequest(method: "ping", params: [:]) { [weak self] result in
            let elapsed = Date().timeIntervalSince(start)
            switch result {
            case .success:
                self?.log("[info] Ping reply in \(String(format: "%.1f ms", elapsed * 1000))", .info)
                completion?(true, elapsed)
            case .failure(let err):
                self?.log("[error] Ping failed: \(err.localizedDescription)", .stderr)
                completion?(false, elapsed)
            }
        }
    }

    func callTool(name: String, arguments: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        log("[info] Calling tool '\(name)' with arguments: \(arguments)", .info)

        sendRequest(method: "tools/call", params: params) { [weak self] result in
            switch result {
            case .success(let res):
                var output = ""
                if let content = res["content"] as? [[String: Any]] {
                    for item in content {
                        if let text = item["text"] as? String {
                            output += text + "\n"
                        }
                    }
                }
                if output.isEmpty {
                    if let data = try? JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted]),
                       let str = String(data: data, encoding: .utf8) {
                        output = str
                    } else {
                        output = "(empty response)"
                    }
                }
                let isErr = (res["isError"] as? Bool) ?? false
                self?.log(isErr ? "[error] Tool returned error: \(output)" : "[info] Tool result:\n\(output)", isErr ? .stderr : .stdout)
                completion(.success(output.trimmingCharacters(in: .whitespacesAndNewlines)))
            case .failure(let err):
                self?.log("[error] Tool call error: \(err.localizedDescription)", .stderr)
                completion(.failure(err))
            }
        }
    }

    func sendRequest(method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        lock.lock()
        let id = nextRequestId
        nextRequestId += 1
        pendingHandlers[id] = { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
        lock.unlock()

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              let jsonStr = String(data: data, encoding: .utf8) else {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "MCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize JSON-RPC payload"])))
            }
            return
        }

        log("--> \(jsonStr)", .stdout)
        writePayload(data: data, jsonString: jsonStr)

        // Timeout handler: 120s for initialize (OAuth discovery, npx package download), 45s for others
        let timeoutSeconds: Double = (method == "initialize") ? 120.0 : 45.0
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.pendingHandlers.removeValue(forKey: id)
            self.lock.unlock()
            if let handler {
                self.log("[error] Request #\(id) (\(method)) timed out after \(Int(timeoutSeconds))s", .stderr)
                handler(.failure(NSError(domain: "MCP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Request #\(id) (\(method)) timed out after \(Int(timeoutSeconds))s"])))
            }
        }
    }

    func sendNotification(method: String, params: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        log("--> \(jsonStr)", .stdout)
        writePayload(data: data, jsonString: jsonStr)
    }

    private func writePayload(data: Data, jsonString: String) {
        if let stdin = stdinPipe {
            var toWrite = data
            toWrite.append(contentsOf: [0x0A]) // \n
            try? stdin.fileHandleForWriting.write(contentsOf: toWrite)
        } else if let postURL = sseEndpointURL ?? currentConfig.flatMap({ URL(string: $0.url) }) {
            var req = URLRequest(url: postURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            if let headers = currentConfig?.headers {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            URLSession.shared.dataTask(with: req) { [weak self] respData, _, err in
                if let err {
                    self?.log("[error] HTTP POST error: \(err.localizedDescription)", .stderr)
                } else if let respData, !respData.isEmpty, let respText = String(data: respData, encoding: .utf8) {
                    self?.handleIncomingJSONRPC(respText)
                }
            }.resume()
        }
    }

    private func handleIncomingJSONRPC(_ line: String) {
        log("<-- \(line)", .stdout)

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = json["id"] as? Int {
            lock.lock()
            let handler = pendingHandlers.removeValue(forKey: id)
            lock.unlock()

            if let handler {
                DispatchQueue.main.async {
                    if let result = json["result"] as? [String: Any] {
                        handler(.success(result))
                    } else if let err = json["error"] as? [String: Any] {
                        let msg = (err["message"] as? String) ?? "MCP error \(err["code"] ?? -1)"
                        handler(.failure(NSError(domain: "MCP", code: (err["code"] as? Int) ?? -1, userInfo: [NSLocalizedDescriptionKey: msg])))
                    } else {
                        handler(.success(json))
                    }
                }
            }
        }
    }

    private func log(_ message: String, _ kind: OutputKind) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(formatted, kind)
        }
    }
}
