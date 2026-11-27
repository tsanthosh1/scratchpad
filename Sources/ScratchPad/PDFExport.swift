import AppKit
import WebKit

/// Prints a standalone HTML page to a paginated PDF file through an offscreen web view.
final class PDFExport: NSObject, WKNavigationDelegate {
    private static var running: Set<PDFExport> = []

    private let webView: WKWebView
    private let url: URL
    private weak var window: NSWindow?
    private let completion: (Bool) -> Void

    private init(url: URL, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
        self.url = url
        self.window = window
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
    }

    /// `window` hosts the (invisible) print operation; `completion` runs on the main thread.
    static func write(html: String, to url: URL, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let export = PDFExport(url: url, window: window, completion: completion)
        running.insert(export)
        export.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 42
        info.bottomMargin = 42
        info.leftMargin = 40
        info.rightMargin = 40

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        guard let window = window ?? NSApp.keyWindow else {
            finish(operation.run())
            return
        }
        operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        finish(success)
    }

    /// The modal print operation may report back on its own worker thread.
    private func finish(_ success: Bool) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.finish(success) } }
        guard Self.running.remove(self) != nil else { return }
        completion(success && FileManager.default.fileExists(atPath: url.path))
    }
}
