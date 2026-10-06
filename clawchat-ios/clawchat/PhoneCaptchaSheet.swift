import SwiftUI
import WebKit

struct PhoneCaptchaSheet: View {
    let challenge: PhoneCaptchaChallenge
    let completion: (Result<String, PhoneCaptchaError>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhoneCaptchaWebView(challenge: challenge, completion: completion)
                .navigationTitle(L10n.t("安全验证", "Security verification"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消", "Cancel")) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PhoneCaptchaWebView: UIViewRepresentable {
    let challenge: PhoneCaptchaChallenge
    let completion: (Result<String, PhoneCaptchaError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(challenge: challenge, completion: completion) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "phoneCaptcha")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.accessibilityIdentifier = "auth.phone-verification-webview"
        // No bearer token, SMS code, or phone number is put into this request or URL.
        webView.load(URLRequest(url: challenge.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        context.coordinator.startDeadline()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "phoneCaptcha")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let challenge: PhoneCaptchaChallenge
        let completion: (Result<String, PhoneCaptchaError>) -> Void
        private var finished = false
        private var deadline: Task<Void, Never>?

        init(challenge: PhoneCaptchaChallenge, completion: @escaping (Result<String, PhoneCaptchaError>) -> Void) {
            self.challenge = challenge
            self.completion = completion
        }

        func startDeadline() {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.finish(.failure(.expired))
            }
        }

        func invalidate() { finished = true; deadline?.cancel(); deadline = nil }

        private func finish(_ result: Result<String, PhoneCaptchaError>) {
            guard !finished else { return }
            invalidate()
            completion(result)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "phoneCaptcha",
                  challenge.acceptsMessage(from: message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame),
                  let body = message.body as? [String: String], let event = body["event"] else { return }
            switch event {
            case "verified":
                guard let token = body["token"], !token.isEmpty, token.count <= 2048 else { finish(.failure(.failed)); return }
                finish(.success(token))
            case "expired", "timeout": finish(.failure(.expired))
            case "error": finish(.failure(.failed))
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame != false {
                let allowed = challenge.acceptsMessage(from: url, isMainFrame: true)
                decisionHandler(allowed ? .allow : .cancel)
                if !allowed { finish(.failure(.failed)) }
                return
            }
            // Turnstile uses subframes and about:blank/srcdoc internally.
            let allowed = (url.scheme == "https" && url.host == "challenges.cloudflare.com") || ["about:blank", "about:srcdoc"].contains(url.absoluteString) || ServiceEndpointConfiguration.hasSameOrigin(challenge.url, url)
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                decisionHandler(.cancel); finish(.failure(.failed)); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(.failed)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(.failed)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(.failed)) }
    }
}
