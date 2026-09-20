import SwiftUI
import WebKit

/// The Meta sign-in sheet. It runs the tokens query, opens the validated
/// auth.meta.com entry page, intercepts the fb-viewapp://frl_login callback,
/// and exchanges the blob for the ar user session.
struct MetaLoginView: View {
    var onSession: (MetaSession) -> Void
    var onCancel: () -> Void
    enum Phase { case querying, signingIn, exchanging }
    @State private var phase: Phase = .querying
    @State private var error: String?
    @State private var tokens: MetaAuth.SSOTokens?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("sign in with your meta account").font(.system(size: 17, weight: .medium))
                    Text("kinesis needs your account once to claim a new band.")
                        .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                }
                Spacer()
                Button("cancel") { onCancel() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 14)
            ZStack {
                switch phase {
                case .querying:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("starting the sign-in…").font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    }
                case .signingIn:
                    if let url = tokens?.authEntryURL {
                        AuthWebView(url: url) { handleCallback($0) }
                    }
                case .exchanging:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        Text("claiming your band…").font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error {
                ErrorNote(text: error).padding(.horizontal, 26).padding(.bottom, 8)
            }
        }.frame(width: 640, height: 620)
        .task {
            do {
                tokens = try await MetaAuth.tokensQuery()
                phase = .signingIn
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func handleCallback(_ url: URL) {
        guard phase == .signingIn, let tokens else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let token = items.first(where: { $0.name == "token" })?.value
        let blob = items.first(where: { $0.name == "blob" })?.value
        guard let blob, !blob.isEmpty, MetaAuth.callbackMatches(token, nativeSSOToken: tokens.nativeSSOToken) else {
            error = "meta didn't confirm this sign-in. try again."
            return
        }
        phase = .exchanging
        Task {
            do {
                let frl = try await MetaAuth.decryptBlob(blob, requestToken: tokens.nativeSSOToken)
                onSession(try await MetaAuth.login(frlAccessToken: frl))
            } catch {
                self.error = error.localizedDescription
                phase = .signingIn
            }
        }
    }
}

private struct AuthWebView: NSViewRepresentable {
    let url: URL
    let onCallback: (URL) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webview = WKWebView(frame: .zero, configuration: configuration)
        webview.navigationDelegate = context.coordinator
        webview.uiDelegate = context.coordinator
        webview.load(URLRequest(url: url))
        return webview
    }

    func updateNSView(_ webview: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCallback: (URL) -> Void
        weak var webview: WKWebView?

        init(onCallback: @escaping (URL) -> Void) { self.onCallback = onCallback }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let text = url.absoluteString
            // The login finishes with a custom-scheme redirect that carries the
            // validated token and the encrypted blob.
            if url.scheme?.lowercased() == "fb-viewapp" || text.contains("frl_login") {
                decisionHandler(.cancel)
                onCallback(url)
            } else {
                decisionHandler(url.scheme?.lowercased() == "https" || text == "about:blank" ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
