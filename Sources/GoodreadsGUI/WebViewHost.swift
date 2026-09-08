import SwiftUI
import WebKit

/// Hosts the shared WKWebView. Used for the sign-in sheet, and for the
/// debug window — the equivalent of the CLI's `--no-headless`.
struct WebViewHost: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        WebSession.shared.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

struct SignInSheet: View {
    @ObservedObject private var session = WebSession.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Goodreads")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") {
                    Task {
                        await session.refreshSignInState()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            WebViewHost()
                .frame(minWidth: 700, minHeight: 620)

            Divider()

            Text("This is Goodreads' own sign-in page. Your password goes straight to Amazon — the app never sees it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .task { await session.beginSignIn() }
    }
}

struct BrowserSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page view")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            WebViewHost().frame(minWidth: 800, minHeight: 600)
        }
    }
}
