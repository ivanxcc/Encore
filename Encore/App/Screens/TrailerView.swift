import SwiftUI
import EncoreKit
#if canImport(WebKit)
import WebKit
#endif

/// Plays a title's official trailer at full quality. iPhone, iPad, and Mac use YouTube's own embedded
/// player, which streams adaptively up to 1080p or 4K; Apple TV, which has no web view, hands the
/// trailer to the YouTube app.
enum Trailers {
    /// The best trailer known for a title: TMDB's official one, else the one Cinemeta lists.
    static func youTubeID(extras: TitleExtras?, meta: MetaDetail?) -> String? {
        if let trailer = extras?.trailer, trailer.site == "YouTube" { return trailer.key }
        return meta?.trailers?.first { ($0.type ?? "Trailer") == "Trailer" }?.source ?? meta?.trailers?.first?.source
    }

    #if os(tvOS)
    static var canPlay: Bool {
        guard let url = URL(string: "youtube://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func open(_ id: String) {
        guard let url = URL(string: "youtube://watch/\(id)") else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

#if !os(tvOS)
struct TrailerView: View {
    let videoID: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            YouTubePlayer(videoID: videoID)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            CloseButton { dismiss() }
                .padding(20)
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 600)
        #endif
        .accessibilityLabel("\(title) trailer")
    }
}

/// YouTube's official embedded (IFrame) player: no ads injected by us, full adaptive quality, captions.
private struct YouTubePlayer {
    let videoID: String

    var html: String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?autoplay=1&playsinline=1&rel=0&modestbranding=1&iv_load_policy=3&vq=hd2160"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body></html>
        """
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        #endif
        // youtube-nocookie requires a page origin; give it one so the embed is allowed to play.
        view.loadHTMLString(html, baseURL: URL(string: "https://encore.app"))
        return view
    }
}

#if os(macOS)
extension YouTubePlayer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension YouTubePlayer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
