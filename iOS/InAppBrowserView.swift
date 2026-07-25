import SwiftUI
import WebKit

/// A custom in-app browser modelled on X/Twitter's: the web page fills its pane
/// and a floating rounded toolbar sits near the bottom (close, back, a centered
/// domain pill with a share/copy/open menu, and refresh), with a slim load-
/// progress line up top. Its host animates the pane's lower edge so the original
/// reader remains visible underneath during and after the transition.
struct InAppBrowserView: View {
    @StateObject private var model: BrowserModel
    @Environment(\.openURL) private var openURL
    private let startURL: URL
    /// Called when the close button is tapped (the host owns dismissal, since this
    /// is revealed behind the reader rather than presented as a sheet).
    var onClose: () -> Void = {}

    init(url: URL, onClose: @escaping () -> Void = {}) {
        self.startURL = url
        self.onClose = onClose
        _model = StateObject(wrappedValue: BrowserModel(url: url))
    }

    var body: some View {
        WebViewContainer(webView: model.webView)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { progressLine }
            .overlay(alignment: .bottom) { toolbar }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressLine: some View {
        if model.isLoading && model.progress < 1 {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * model.progress, height: 2.5)
                    .animation(.easeInOut(duration: 0.2), value: model.progress)
            }
            .frame(height: 2.5)
        }
    }

    // MARK: - Toolbar

    /// Dark, semi-transparent chrome (like X's) rather than a light material —
    /// reads clearly over any page, light or dark.
    private static let chromeColor = Color.black.opacity(0.68)

    private var toolbar: some View {
        HStack(spacing: 12) {
            circleButton("xmark") { onClose() }
            circleButton("chevron.left") { model.goBack() }
                .disabled(!model.canGoBack)
                .opacity(model.canGoBack ? 1 : 0.35)

            Spacer(minLength: 8)

            Menu {
                Button {
                    openURL(model.currentURL ?? startURL)
                } label: { Label("Open in Safari", systemImage: "safari") }
                Button {
                    UIPasteboard.general.url = model.currentURL ?? startURL
                } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                ShareLink(item: model.currentURL ?? startURL) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.host)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Self.chromeColor))
            }

            Spacer(minLength: 8)

            circleButton("arrow.clockwise") { model.reload() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Self.chromeColor))
        }
    }
}

/// Holds the `WKWebView` and mirrors the bits the toolbar needs (can-go-back,
/// load progress, current host) via KVO. Plain `ObservableObject` — WKWebView KVO
/// is delivered on the main thread, so the published updates land on main.
final class BrowserModel: ObservableObject {
    @Published var canGoBack = false
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var host: String

    let webView: WKWebView
    private var observers: [NSKeyValueObservation] = []

    var currentURL: URL? { webView.url }

    init(url: URL) {
        host = url.host ?? url.absoluteString
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            self?.canGoBack = wv.canGoBack
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            self?.progress = wv.estimatedProgress
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            self?.isLoading = wv.isLoading
        })
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            if let host = wv.url?.host { self?.host = host }
        })

        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }
}

/// Hosts the model's `WKWebView` in SwiftUI.
private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
