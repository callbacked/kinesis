import SwiftUI
import WebKit

/// The Meta sign-in sheet. It first says what is about to happen and why.
/// Nothing contacts Meta until the person continues. It then runs the tokens
/// query, opens the validated auth.meta.com entry page, intercepts the
/// fb-viewapp://frl_login callback, and exchanges the blob for the ar session.
struct MetaLoginView: View {
    var onSession: (MetaSession) -> Void
    var onCancel: () -> Void
    enum Phase { case intro, querying, signingIn, exchanging }
    @State private var phase: Phase = .intro
    @State private var error: String?
    @State private var tokens: MetaAuth.SSOTokens?
    @State private var host = "auth.meta.com"

    var body: some View {
        VStack(spacing: 0) {
            if phase == .intro { intro } else { signIn }
        }
        .frame(width: 640, height: 620)
        .background(KinesisStyle.paper).foregroundStyle(KinesisStyle.ink)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "one time")
            Text("sign in with meta.").font(.system(size: 34)).tracking(-1.3).padding(.top, 10)
            Text("your band belongs to your meta account. claiming it for this Mac needs that account once.")
                .font(.system(size: 14)).foregroundStyle(KinesisStyle.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            VStack(alignment: .leading, spacing: 22) {
                promise("lock.shield", "you sign in on meta’s own page",
                        "kinesis opens auth.meta.com and only receives the session that page hands back.")
                promise("key", "one token, in your keychain",
                        "it lets kinesis claim your band. you can sign out on the band page whenever you want.")
                promise("arrow.uturn.backward", "the band stays yours",
                        "it stays on your meta account. a factory reset releases it from this Mac.")
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(KinesisStyle.surface, in: RoundedRectangle(cornerRadius: 16)).padding(.top, 30)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Spacer()
                Button("not now") { onCancel() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                Button { begin() } label: {
                    HStack(spacing: 22) {
                        Text("continue to meta")
                        Image(systemName: "arrow.right")
                    }
                }.buttonStyle(KinesisButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 44).padding(.top, 44).padding(.bottom, 32)
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light)).frame(width: 24)
                .foregroundStyle(KinesisStyle.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // The page's real host, so it is plain where the password goes.
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(host).font(.system(size: 12, weight: .medium))
                Spacer()
                Button("cancel") { onCancel() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
            }.foregroundStyle(KinesisStyle.secondary)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(KinesisStyle.line).frame(height: 1) }
            ZStack {
                switch phase {
                case .intro: EmptyView()
                case .querying: waiting("opening meta’s sign-in…")
                case .signingIn:
                    if let url = tokens?.authEntryURL {
                        AuthWebView(url: url, onHost: { host = $0 }) { handleCallback($0) }
                    }
                case .exchanging: waiting("finishing the sign-in…")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error {
                HStack {
                    ErrorNote(text: error)
                    Spacer()
                    if phase == .querying {
                        Button("try again") { begin() }.buttonStyle(KinesisButtonStyle())
                    }
                }.padding(.horizontal, 22).padding(.vertical, 12)
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 14) {
            if error == nil { ProgressView().controlSize(.regular) }
            Text(text).font(.system(size: 12)).foregroundStyle(KinesisStyle.secondary)
        }
    }

    private func begin() {
        error = nil
        phase = .querying
        Task {
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
    var onHost: (String) -> Void = { _ in }
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

    func makeCoordinator() -> Coordinator { Coordinator(onHost: onHost, onCallback: onCallback) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onHost: (String) -> Void
        let onCallback: (URL) -> Void
        weak var webview: WKWebView?

        init(onHost: @escaping (String) -> Void, onCallback: @escaping (URL) -> Void) {
            self.onHost = onHost
            self.onCallback = onCallback
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let host = webView.url?.host { onHost(host) }
        }

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
