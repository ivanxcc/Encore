import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Page titles and back navigation that work with the Mac's floating window controls.
///
/// On the Mac, Encore draws its own controls over the artwork (a sidebar button, a back button, and a
/// search pill) instead of a window toolbar, so nothing grey sits across the top of the window in full
/// screen. Pushed pages register here so the floating back button can go back from them, and page
/// titles are drawn in the page, clear of the controls.
extension View {
    /// The page's title: the navigation title on iPhone, iPad, and Apple TV; a large title in the page on
    /// the Mac, below the floating controls.
    func pageTitle(_ title: String) -> some View {
        modifier(PageTitle(title: title))
    }

    /// Mac: a pushed page fades in once it has been laid out at the window's size, so the first frame of
    /// a push (laid out narrower than the window, artwork and controls out of line) is never seen.
    /// Elsewhere it does nothing.
    func revealWhenLaidOut() -> some View {
        modifier(RevealWhenLaidOut())
    }

    /// Marks a page pushed onto a navigation stack, so the Mac's back button can return from it.
    func pushedPage() -> some View {
        modifier(PushedPage())
    }
}

private struct PageTitle: ViewModifier {
    let title: String
    #if os(macOS)
    @Environment(\.macChromeInset) private var inset
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.edge)
                    .padding(.top, inset + 6)
                    .padding(.bottom, 4)
                    // Rows scrolling up fade out under the title instead of running through it.
                    .background {
                        LinearGradient(stops: [.init(color: Theme.Colors.canvas, location: 0),
                                               .init(color: Theme.Colors.canvas.opacity(0.9), location: 0.7),
                                               .init(color: Theme.Colors.canvas.opacity(0), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .padding(.bottom, -20)
                            .ignoresSafeArea()
                    }
            }
        #else
        content.navigationTitle(title)
        #endif
    }
}

private struct RevealWhenLaidOut: ViewModifier {
    #if os(macOS)
    @State private var shown = false
    @State private var width: CGFloat = 0
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .opacity(shown ? 1 : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // Shown once the page is as wide as the window and has held that size for a moment.
            .task(id: width) {
                guard !shown else { return }
                let window = NSApp.keyWindow?.contentLayoutRect.width ?? 0
                guard width > 0, width >= window - 2 else {
                    // Never leave a page hidden: give up waiting after a short while.
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.3)) { shown = true }
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { shown = true }
            }
        #else
        content
        #endif
    }
}

private struct PushedPage: ViewModifier {
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macNavigator) private var navigator
    @State private var id = UUID()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            // The floating back button replaces the toolbar's, which would bring a toolbar back.
            .navigationBarBackButtonHidden(true)
            .onAppear { navigator?.appeared(id, back: dismiss) }
            .onDisappear { navigator?.disappeared(id) }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// One section's navigation on the Mac.
///
/// Titles and episodes (`Route`s) don't use the navigation stack's push, which lays a page out at the
/// wrong size for its first frames and then jumps: they open as layers over the section, laid out at
/// the window's size from the first frame, and dissolve in over the artwork they came from. Other
/// pages (Settings' subpages) push normally and register here, so the floating back button can return
/// from either, newest first.
@MainActor
final class MacNavigator: ObservableObject {
    struct Layer: Identifiable { let id = UUID(); let route: Route }
    private struct Page { let id: UUID; let back: DismissAction }

    @Published private(set) var layers: [Layer] = []
    /// Layers currently faded in. A layer is added invisible and faded in, and on the way back faded out
    /// before it is removed, so both directions are the same smooth dissolve (removing it outright made
    /// going back abrupt).
    @Published private(set) var shown: Set<UUID> = []
    @Published private var pages: [Page] = []
    /// Gets a route's page ready (its details, logo, and artwork) so it appears complete; set by the app.
    var prepare: ((Route) async -> Void)?
    private var opening = false

    var canGoBack: Bool { !pages.isEmpty || !layers.isEmpty }

    /// The path a section's navigation stack is bound to: always empty to the stack, so a link to a
    /// `Route` opens a layer here instead of pushing.
    var path: Binding<[Route]> {
        Binding(get: { [] }, set: { [weak self] newPath in
            if let route = newPath.last { self?.open(route) }
        })
    }

    static let fade = Animation.easeInOut(duration: 0.42)

    /// Opens a page once it's ready, or after a second at most, then dissolves it in whole.
    func open(_ route: Route) {
        guard !opening else { return }
        opening = true
        Task {
            if let prepare {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await prepare(route) }
                    group.addTask { try? await Task.sleep(for: .seconds(1)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            let layer = Layer(route: route)
            layers.append(layer)
            opening = false
            // One frame laid out invisibly at full size, then the dissolve.
            try? await Task.sleep(for: .milliseconds(16))
            _ = withAnimation(Self.fade) { shown.insert(layer.id) }
        }
    }

    func appeared(_ id: UUID, back: DismissAction) {
        guard !pages.contains(where: { $0.id == id }) else { return }
        pages.append(Page(id: id, back: back))
    }

    func disappeared(_ id: UUID) {
        pages.removeAll { $0.id == id }
    }

    func goBack() {
        if let page = pages.last {
            page.back()
        } else if let top = layers.last, shown.contains(top.id) {
            withAnimation(Self.fade) {
                _ = shown.remove(top.id)
            } completion: { [weak self] in
                self?.layers.removeAll { $0.id == top.id }
            }
        }
    }

    func reset() {
        layers = []
        shown = []
        pages = []
    }
}

extension EnvironmentValues {
    /// The navigator of the Mac section a view is in (nil outside the main window's sections).
    @Entry var macNavigator: MacNavigator? = nil
    /// How far the floating window controls reach down the window; page titles start below it.
    @Entry var macChromeInset: CGFloat = 0
}
#endif
