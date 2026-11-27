import AppKit
import Foundation

private final class FormRow: NSStackView {
    init(title: String, field: NSView, labelWidth: CGFloat = 85) {
        let label = NSTextField.label(title, size: 12)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 10
        addArrangedSubview(label)
        addArrangedSubview(field)
        field.setContentHuggingPriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Tester page for Model Context Protocol (MCP) servers over Stdio and SSE/HTTP.
final class MCPTesterPage: ToolPageController, NSTextFieldDelegate {
    private let mcpClient = MCPClient()
    private var currentConfig = MCPConfig()
    private var isSyncing = false
    private var discoveredTools: [MCPTool] = []
    private var selectedTool: MCPTool?

    // Left Pane (Editor)
    private let editor = CardTextView(editable: true)
    private lazy var editorCard: ToolCard = ToolCard.text("MCP Config (JSON / Command)", editor, actions: [
        pasteButton(editor),
        ToolActionButton(title: "Format JSON", symbol: "wand.and.stars", tip: "Format configuration as JSON") { [weak self] in
            self?.formatAsJSON()
        },
        copyButton { [weak self] in self?.editor.string ?? "" },
        clearButton(editor),
    ])

    // Right Pane - Connection Card
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField.label("Disconnected", size: 12)
    private var testButton: ToolActionButton!
    private var pingButton: ToolActionButton!
    private var listToolsButton: ToolActionButton!

    // Right Pane - Configuration Card
    private var transportSegment: ClosureSegmented!
    private let nameField = makeField(placeholder: "e.g. mcp-remote")
    private let commandField = makeField(placeholder: "e.g. npx, uvx, node, python3")
    private let argsField = makeField(placeholder: "e.g. -y mcp-remote http://localhost:8000/sse")
    private let envField = makeField(placeholder: "e.g. DEBUG=1, API_KEY=xyz")
    private let urlField = makeField(placeholder: "e.g. http://localhost:8000/sse")
    private let headersField = makeField(placeholder: "e.g. Authorization: Bearer token")
    private let stdioStack = NSStackView()
    private let sseStack = NSStackView()

    // Right Pane - Tools & Execution Card
    private let toolsBadge = NSTextField.label("0 tools", size: 11)
    private let toolsEmptyLabel = NSTextField.label("No tools discovered yet. Click 'Test Connection' or 'List Tools' to inspect.", size: 12)
    private let toolsContainer = NSStackView()
    private let toolPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let toolParametersLabel = NSTextField(wrappingLabelWithString: "")
    private let argumentsTextView = CardTextView(editable: true)
    private var runToolButton: ToolActionButton!
    private let toolResultTextView = CardTextView(editable: false)

    // Right Pane - Traffic & Logs Card
    private let logTextView = CardTextView(editable: false)

    private static let defaultConfig = """
    {
      "mcpServers": {
        "mcp-remote": {
          "command": "npx",
          "args": [
            "-y",
            "mcp-remote",
            "http://localhost:8000/sse"
          ]
        }
      }
    }
    """

    init() {
        super.init(toolId: "mcp")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        mcpClient.disconnect()
    }

    override func loadView() {
        setupEditor()
        setupConnectionCard()
        setupConfigCard()
        setupToolsCard()
        setupLogsCard()
        setupClientCallbacks()

        let connectionCard = makeConnectionCard()
        let configCard = makeConfigCard()
        let toolsCard = makeToolsCard()
        let logsCard = makeLogsCard()

        let rightScroll = ScrollStack([
            connectionCard,
            configCard,
            toolsCard,
            logsCard
        ], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))

        let split = GapSplitView()
        split.ratio = 0.44
        split.sideBySideMinWidth = 760
        split.addArrangedSubview(editorCard)
        split.addArrangedSubview(rightScroll)
        split.setContentHuggingPriority(.init(1), for: .vertical)

        view = ToolUI.page([split], spacing: 0)

        // Load saved or default config
        let initialText = value("mcpConfig") ?? Self.defaultConfig
        editor.string = initialText
        editorTextDidChange()
    }

    override func focus() {
        view.window?.makeFirstResponder(editor)
    }

    override var primaryOutput: String? {
        editor.string
    }

    // MARK: - Setup Helpers

    private static func makeField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        return field
    }

    private func setupEditor() {
        editor.setPlaceholder("Paste MCP JSON configuration or command line, e.g. \"npx -y mcp-remote http://localhost:8000/sse\"")
        editor.onChange = { [weak self] in
            self?.editorTextDidChange()
        }
    }

    private func setupConnectionCard() {
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Status")
        statusDot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        statusDot.contentTintColor = .systemGray
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        testButton = ToolActionButton(title: "Test Connection", symbol: "bolt.fill", tip: "Connect and handshake with MCP server", style: .prominent) { [weak self] in
            self?.toggleConnection()
        }

        pingButton = ToolActionButton(title: "Ping", symbol: "waveform", tip: "Measure round-trip ping time") { [weak self] in
            self?.ping()
        }

        listToolsButton = ToolActionButton(title: "List Tools", symbol: "wrench.and.screwdriver", tip: "Query tools list") { [weak self] in
            self?.listTools()
        }
    }

    private func setupConfigCard() {
        transportSegment = ClosureSegmented(["Stdio (Command)", "SSE / HTTP (URL)"], selected: 0)
        transportSegment.onChange = { [weak self] _ in
            self?.updateTransportVisibility()
            self?.uiFieldDidChange()
        }

        for field in [nameField, commandField, argsField, envField, urlField, headersField] {
            field.delegate = self
        }

        stdioStack.orientation = .vertical
        stdioStack.alignment = .leading
        stdioStack.spacing = 8
        stdioStack.addArrangedSubview(FormRow(title: "Command", field: commandField))
        stdioStack.addArrangedSubview(FormRow(title: "Arguments", field: argsField))
        stdioStack.addArrangedSubview(FormRow(title: "Environment", field: envField))
        for v in stdioStack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stdioStack.widthAnchor).isActive = true
        }

        sseStack.orientation = .vertical
        sseStack.alignment = .leading
        sseStack.spacing = 8
        sseStack.addArrangedSubview(FormRow(title: "Server URL", field: urlField))
        sseStack.addArrangedSubview(FormRow(title: "Headers", field: headersField))
        for v in sseStack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: sseStack.widthAnchor).isActive = true
        }

        updateTransportVisibility()
    }

    private func setupToolsCard() {
        toolsBadge.textColor = .secondaryLabelColor
        toolsEmptyLabel.textColor = .tertiaryLabelColor

        toolPopUp.target = self
        toolPopUp.action = #selector(toolPopUpChanged)

        toolDescriptionLabel.font = .systemFont(ofSize: 12)
        toolDescriptionLabel.textColor = .labelColor

        toolParametersLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        toolParametersLabel.textColor = .secondaryLabelColor

        runToolButton = ToolActionButton(title: "Run Tool", symbol: "play.fill", tip: "Invoke the selected tool with arguments", style: .prominent) { [weak self] in
            self?.runSelectedTool()
        }

        argumentsTextView.setPlaceholder("{\n  \"key\": \"value\"\n}")
        toolResultTextView.setPlaceholder("Tool execution output will appear here…")

        toolsContainer.orientation = .vertical
        toolsContainer.alignment = .leading
        toolsContainer.spacing = 8
        toolsContainer.isHidden = true

        let toolRow = NSStackView(views: [toolPopUp, ToolUI.spacer(), runToolButton])
        toolRow.alignment = .centerY

        let resetArgsBtn = ToolActionButton(title: "Reset Sample", symbol: "arrow.counterclockwise", tip: "Reset to default sample arguments") { [weak self] in
            self?.resetSampleArguments()
        }
        let argsHeader = NSStackView(views: [
            NSTextField.label("Arguments (JSON):", size: 11),
            ToolUI.spacer(),
            resetArgsBtn
        ])
        argsHeader.alignment = .centerY

        let argScroll = makeCardScroll(for: argumentsTextView, minHeight: 70, maxHeight: 110)
        let resultScroll = makeCardScroll(for: toolResultTextView, minHeight: 85, maxHeight: 140)

        toolsContainer.addArrangedSubview(toolRow)
        toolsContainer.addArrangedSubview(toolDescriptionLabel)
        toolsContainer.addArrangedSubview(toolParametersLabel)
        toolsContainer.addArrangedSubview(argsHeader)
        toolsContainer.addArrangedSubview(argScroll)
        toolsContainer.addArrangedSubview(NSTextField.label("Result:", size: 11))
        toolsContainer.addArrangedSubview(resultScroll)

        for v in toolsContainer.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: toolsContainer.widthAnchor).isActive = true
        }
    }

    private func setupLogsCard() {
        logTextView.setPlaceholder("JSON-RPC traffic and stderr logs will stream here…")
    }

    private func setupClientCallbacks() {
        mcpClient.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateConnectionState(state)
            }
        }

        mcpClient.onLog = { [weak self] msg, kind in
            DispatchQueue.main.async {
                self?.appendLog(msg, kind: kind)
            }
        }

        mcpClient.onToolsReceived = { [weak self] tools in
            DispatchQueue.main.async {
                self?.updateTools(tools)
            }
        }
    }

    // MARK: - Card Builders

    private func makeConnectionCard() -> NSView {
        let row = NSStackView(views: [
            statusDot,
            statusLabel,
            ToolUI.spacer(),
            testButton,
            pingButton,
            listToolsButton
        ])
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let card = ToolCard(title: "Connection", content: row, footer: false)
        card.heightAnchor.constraint(equalToConstant: 74).isActive = true
        return card
    }

    private func makeConfigCard() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let segmentRow = NSStackView(views: [
            NSTextField.label("Transport:", size: 12),
            transportSegment
        ])
        segmentRow.alignment = .centerY
        segmentRow.spacing = 10

        stack.addArrangedSubview(segmentRow)
        stack.addArrangedSubview(FormRow(title: "Server Name", field: nameField))
        stack.addArrangedSubview(stdioStack)
        stack.addArrangedSubview(sseStack)

        for v in stack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        return ToolCard(title: "Server Configuration", content: stack, footer: false)
    }

    private func makeToolsCard() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        stack.addArrangedSubview(toolsEmptyLabel)
        stack.addArrangedSubview(toolsContainer)

        for v in stack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        let promptsBtn = ToolActionButton(title: "Prompts", symbol: "bubble.left.and.bubble.right", tip: "Query server prompts") { [weak self] in
            self?.mcpClient.listPrompts()
        }
        let resourcesBtn = ToolActionButton(title: "Resources", symbol: "folder", tip: "Query server resources") { [weak self] in
            self?.mcpClient.listResources()
        }

        return ToolCard(title: "Tools & Execution", content: stack, actions: [toolsBadge, promptsBtn, resourcesBtn], footer: false)
    }

    private func makeLogsCard() -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = logTextView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        let copyBtn = copyButton(title: "Copy") { [weak self] in
            self?.logTextView.string ?? ""
        }
        let clearBtn = ToolActionButton(title: nil, symbol: "trash", tip: "Clear logs") { [weak self] in
            self?.logTextView.string = ""
        }

        return ToolCard(title: "Traffic & Console Logs", content: scroll, actions: [copyBtn, clearBtn], footer: false)
    }

    private func makeCardScroll(for textView: CardTextView, minHeight: CGFloat, maxHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4)
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight).isActive = true
        return scroll
    }

    // MARK: - Synchronization & Events

    private func updateTransportVisibility() {
        let isStdio = transportSegment.selectedSegment == 0
        stdioStack.isHidden = !isStdio
        sseStack.isHidden = isStdio
    }

    func controlTextDidChange(_ obj: Notification) {
        uiFieldDidChange()
    }

    private func uiFieldDidChange() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        currentConfig.name = name.isEmpty ? "server" : name
        currentConfig.transport = transportSegment.selectedSegment == 0 ? .stdio : .sse
        if currentConfig.transport == .stdio {
            currentConfig.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
            let parsed = MCPConfig.parseCommandLine("dummy " + argsField.stringValue)
            currentConfig.args = MCPConfig.normalizeHeaderArgs(parsed.args)
            currentConfig.env = MCPConfig.parseEnvString(envField.stringValue)
        } else {
            currentConfig.url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            currentConfig.headers = MCPConfig.parseHeadersString(headersField.stringValue)
        }

        let json = currentConfig.toJSONString()
        editor.string = json
        store("mcpConfig", json)
        editorCard.setMeta("JSON (\(currentConfig.transport.rawValue))")
    }

    private func editorTextDidChange() {
        guard !isSyncing else { return }
        let text = editor.string
        store("mcpConfig", text)

        guard let parsed = MCPConfig.parse(from: text) else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editorCard.setMeta("")
            } else {
                editorCard.setMeta("Unrecognized format", isError: true)
            }
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        currentConfig = parsed
        nameField.stringValue = parsed.name
        transportSegment.selectedSegment = parsed.transport == .stdio ? 0 : 1
        updateTransportVisibility()

        commandField.stringValue = parsed.command
        argsField.stringValue = parsed.formattedArgs
        envField.stringValue = parsed.envString
        urlField.stringValue = parsed.url
        headersField.stringValue = parsed.headersString

        let isJSON = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        editorCard.setMeta(isJSON ? "JSON (\(parsed.transport.rawValue))" : "Command (\(parsed.command))")
    }

    private func formatAsJSON() {
        let json = currentConfig.toJSONString()
        guard !json.isEmpty else { return }
        isSyncing = true
        editor.replaceAll(json)
        isSyncing = false
        store("mcpConfig", json)
        editorCard.setMeta("JSON (\(currentConfig.transport.rawValue))")
    }

    // MARK: - Connection & Actions

    private func toggleConnection() {
        if mcpClient.state.isConnected {
            mcpClient.disconnect()
        } else {
            testConnection()
        }
    }

    private func testConnection() {
        view.window?.makeFirstResponder(nil)

        let trimmed = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let parsed = MCPConfig.parse(from: trimmed) {
                currentConfig = parsed
            } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                appendLog("[error] Invalid JSON configuration. Please check for syntax errors.", kind: .stderr)
                updateConnectionState(.error("Invalid JSON configuration"))
                return
            }
        }

        if currentConfig.transport == .stdio {
            let cmd = currentConfig.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, cmd != "{", cmd != "}", cmd != "[", cmd != "]" else {
                appendLog("[error] Invalid command: '\(cmd)'. Please specify a valid command (e.g. npx, uvx, node).", kind: .stderr)
                updateConnectionState(.error("Invalid command: '\(cmd)'"))
                return
            }
        } else {
            let u = currentConfig.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !u.isEmpty else {
                appendLog("[error] Server URL cannot be empty.", kind: .stderr)
                updateConnectionState(.error("Server URL cannot be empty"))
                return
            }
        }

        mcpClient.connect(config: currentConfig)
    }

    private func ping() {
        if !mcpClient.state.isConnected {
            mcpClient.connect(config: currentConfig)
        }
        pingButton.setTitle("Pinging…")
        pingButton.isEnabled = false
        mcpClient.ping { [weak self] ok, elapsed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pingButton.isEnabled = true
                if ok {
                    self.pingButton.flash(title: String(format: "%.1f ms", elapsed * 1000), symbol: "checkmark")
                } else {
                    self.pingButton.setTitle("Ping")
                    self.pingButton.flash(title: "Failed", symbol: "xmark")
                }
            }
        }
    }

    private func listTools() {
        if !mcpClient.state.isConnected {
            mcpClient.connect(config: currentConfig)
        } else {
            mcpClient.listTools()
        }
    }

    private func updateConnectionState(_ state: MCPConnectionState) {
        switch state {
        case .disconnected:
            statusDot.contentTintColor = .systemGray
            statusLabel.stringValue = "Disconnected"
            statusLabel.textColor = .secondaryLabelColor
            testButton.setTitle("Test Connection")
            testButton.setSymbol("bolt.fill")
            testButton.setStyle(.prominent)
        case .connecting:
            statusDot.contentTintColor = .systemOrange
            statusLabel.stringValue = "Connecting to \(currentConfig.name)…"
            statusLabel.textColor = .systemOrange
            testButton.setTitle("Disconnect")
            testButton.setSymbol("xmark.circle")
            testButton.setStyle(.plain)
        case .connected(let name, let version, let proto):
            statusDot.contentTintColor = .systemGreen
            statusLabel.stringValue = "Connected: \(name) v\(version) · Protocol \(proto)"
            statusLabel.textColor = .systemGreen
            testButton.setTitle("Disconnect")
            testButton.setSymbol("xmark.circle")
            testButton.setStyle(.plain)
        case .error(let message):
            statusDot.contentTintColor = .systemRed
            statusLabel.stringValue = "Error: \(message)"
            statusLabel.textColor = .systemRed
            testButton.setTitle("Test Connection")
            testButton.setSymbol("bolt.fill")
            testButton.setStyle(.prominent)
        }
    }

    private func appendLog(_ message: String, kind: OutputKind) {
        let color: NSColor
        switch kind {
        case .stdout: color = .labelColor
        case .stderr: color = .systemRed
        case .info: color = .systemTeal
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]
        let attributed = NSAttributedString(string: message + "\n", attributes: attrs)
        logTextView.textStorage?.append(attributed)
        logTextView.scrollToEndOfDocument(nil)
    }

    // MARK: - Tools Execution

    private func updateTools(_ tools: [MCPTool]) {
        discoveredTools = tools
        toolsBadge.stringValue = "\(tools.count) tool\(tools.count == 1 ? "" : "s")"

        if tools.isEmpty {
            toolsEmptyLabel.isHidden = false
            toolsEmptyLabel.stringValue = "No tools returned by server."
            toolsContainer.isHidden = true
            selectedTool = nil
        } else {
            toolsEmptyLabel.isHidden = true
            toolsContainer.isHidden = false
            toolPopUp.removeAllItems()
            toolPopUp.addItems(withTitles: tools.map(\.name))
            toolPopUp.selectItem(at: 0)
            selectTool(at: 0)
        }
    }

    @objc private func toolPopUpChanged() {
        selectTool(at: toolPopUp.indexOfSelectedItem)
    }

    private func selectTool(at index: Int) {
        guard discoveredTools.indices.contains(index) else { return }
        let tool = discoveredTools[index]
        selectedTool = tool
        toolDescriptionLabel.stringValue = tool.description ?? "No description provided."
        toolParametersLabel.stringValue = tool.parametersDescription
        argumentsTextView.string = tool.sampleArgumentsJSON()
        toolResultTextView.string = ""
    }

    private func resetSampleArguments() {
        guard let tool = selectedTool else { return }
        argumentsTextView.string = tool.sampleArgumentsJSON()
    }

    private func runSelectedTool() {
        guard let tool = selectedTool else { return }
        let rawArgs = argumentsTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedArgs: [String: Any] = [:]
        if !rawArgs.isEmpty {
            guard let data = rawArgs.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                toolResultTextView.string = "Error: Arguments must be a valid JSON object e.g. {\"key\": \"value\"}"
                return
            }
            parsedArgs = json
        }

        runToolButton.setTitle("Running…")
        runToolButton.isEnabled = false
        toolResultTextView.string = "Executing '\(tool.name)'…"

        mcpClient.callTool(name: tool.name, arguments: parsedArgs) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runToolButton.setTitle("Run Tool")
                self.runToolButton.isEnabled = true
                switch result {
                case .success(let output):
                    self.toolResultTextView.string = output.isEmpty ? "(empty response)" : output
                case .failure(let error):
                    self.toolResultTextView.string = "Error calling tool: \(error.localizedDescription)"
                }
            }
        }
    }
}
