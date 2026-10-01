import Foundation

struct HTTPResponse {
    let request: HTTPRequest
    let status: Int
    let headers: [(name: String, value: String)]
    let body: Data
    let elapsed: TimeInterval
    let finalURL: URL?

    var contentType: String? {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased()
    }

    var bodyText: String? { String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) }

    /// Body as shown to the user: JSON is re-indented, binary is nil.
    func displayBody(indent: Int) -> String? {
        guard isText, let text = bodyText else { return nil }
        if contentType?.contains("json") == true || text.first == "{" || text.first == "[" {
            return JSONPretty.format(text, indent: indent) ?? text
        }
        return text
    }

    var isText: Bool {
        guard let type = contentType else { return String(data: body, encoding: .utf8) != nil }
        if type.hasPrefix("image/") || type.hasPrefix("audio/") || type.hasPrefix("video/") { return false }
        let textual = ["text/", "json", "xml", "html", "javascript", "yaml", "csv", "x-www-form-urlencoded", "graphql"]
        return textual.contains(where: type.contains) || String(data: body, encoding: .utf8) != nil
    }

    var isImage: Bool { contentType?.hasPrefix("image/") == true }

    var language: Language {
        let type = contentType ?? ""
        if type.contains("json") { return .json }
        if type.contains("html") { return .html }
        if type.contains("xml") { return .xml }
        if type.contains("yaml") { return .yaml }
        if type.contains("javascript") { return .javascript }
        if type.contains("css") { return .css }
        if type.contains("markdown") { return .markdown }
        return Language.detect(bodyText ?? "")
    }
}

/// Sends requests from `.http` scratches one after another and reports each result.
final class HTTPClient: NSObject, URLSessionTaskDelegate {
    var onStart: ((Int) -> Void)?
    var onResult: ((Int, Result<HTTPResponse, Error>) -> Void)?
    var onFinish: ((_ cancelled: Bool) -> Void)?
    private(set) var lastResponse: HTTPResponse?
    private var task: Task<Void, Never>?
    private var currentGeneration = UUID()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var isRunning: Bool { task != nil }

    func send(_ requests: [HTTPRequest], baseDirectory: URL) {
        stop()
        let generation = UUID()
        currentGeneration = generation
        task = Task { @MainActor [weak self] in
            for (index, request) in requests.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.onStart?(index)
                let result = await self.perform(request, baseDirectory: baseDirectory)
                guard !Task.isCancelled, self.currentGeneration == generation else { return }
                if case .success(let response) = result { self.lastResponse = response }
                self.onResult?(index, result)
            }
            guard let self, self.currentGeneration == generation else { return }
            self.task = nil
            self.onFinish?(false)
        }
    }

    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        currentGeneration = UUID()
        onFinish?(true)
    }

    private func perform(_ request: HTTPRequest, baseDirectory: URL) async -> Result<HTTPResponse, Error> {
        guard let url = URL(string: request.url)
                ?? URL(string: request.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              url.scheme != nil, url.host != nil else {
            return .failure(HTTPError("Invalid URL: \(request.url)"))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        if let body = request.body {
            do {
                let multipart = request.header("Content-Type")?.lowercased().hasPrefix("multipart/") == true
                urlRequest.httpBody = try Self.bodyData(body, baseDirectory: baseDirectory,
                                                        lineSeparator: multipart ? "\r\n" : "\n")
            } catch {
                return .failure(error)
            }
        }

        let started = Date()
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return .failure(HTTPError("Not an HTTP response")) }
            let headers = http.allHeaderFields
                .map { (name: "\($0.key)", value: "\($0.value)") }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            return .success(HTTPResponse(request: request, status: http.statusCode, headers: headers, body: data,
                                         elapsed: Date().timeIntervalSince(started),
                                         finalURL: http.url == url ? nil : http.url))
        } catch {
            return .failure(error)
        }
    }

    /// Body text where lines of the form `< path` are replaced by that file's bytes.
    static func bodyData(_ body: String, baseDirectory: URL, lineSeparator: String) throws -> Data {
        var data = Data()
        let lines = body.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("< ") {
                let path = (String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path)
                guard let contents = try? Data(contentsOf: url) else { throw HTTPError("Can't read body file \(url.path)") }
                data.append(contents)
            } else {
                data.append(Data(line.utf8))
            }
            if index < lines.count - 1 { data.append(Data(lineSeparator.utf8)) }
        }
        return data
    }

    // MARK: Formatting

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func reason(_ status: Int) -> String {
        let known: [Int: String] = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
            206: "Partial Content", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
            403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
            409: "Conflict", 410: "Gone", 412: "Precondition Failed", 413: "Payload Too Large",
            415: "Unsupported Media Type", 422: "Unprocessable Content", 429: "Too Many Requests",
            500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
            504: "Gateway Timeout",
        ]
        return known[status] ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}
