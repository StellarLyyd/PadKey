import AppKit
import WebKit

final class StudioWebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    private let sensorBridge = PadKeySensorBridge()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(sensorBridge, name: "padkeyBridge")
        controller.addUserScript(WKUserScript(
            source: """
            window.__PADKEY_AGENT_URL__ = 'http://127.0.0.1:8789';
            window.__PADKEY_NATIVE_APP__ = true;
            document.addEventListener('DOMContentLoaded', function () {
              document.documentElement.classList.add('padkey-native');
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        sensorBridge.attach(webView: view)
        return view
    }()

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1).cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadStudioIfNeeded()
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "padkeyBridge")
        sensorBridge.shutdown()
    }

    func reloadStudio() {
        webView.reload()
    }

    func loadStudioIfNeeded() {
        if webView.url == nil {
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:8789/studio/")!))
        }
    }

    func openStudio() {
        let url = URL(string: "http://127.0.0.1:8789/studio/#studio")!
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        } else {
            webView.evaluateJavaScript("""
            window.location.hash = 'studio';
            window.dispatchEvent(new CustomEvent('padkey-native-route', { detail: { area: 'studio' } }));
            """)
        }
    }

    func openAdvanced(_ section: String = "signals") {
        let url = URL(string: "http://127.0.0.1:8789/studio/#advanced/\(section)")!
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        } else {
            webView.evaluateJavaScript("""
            window.location.hash = 'advanced/\(section)';
            window.dispatchEvent(new CustomEvent('padkey-native-route', { detail: { area: 'advanced', advancedView: '\(section)' } }));
            """)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           url.host != "127.0.0.1" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone || type == .cameraAndMicrophone ? .grant : .deny)
    }
}
