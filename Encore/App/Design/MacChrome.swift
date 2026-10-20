import SwiftUI

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
            .navigationTitle(title)
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

private struct PushedPage: ViewModifier {
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macNavigator) private var navigator
    @State private var id = UUID()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear { navigator?.appeared(id, back: dismiss) }
            .onDisappear { navigator?.disappeared(id) }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// One section's pushed pages, newest last; the floating back button dismisses the newest.
@MainActor
final class MacNavigator: ObservableObject {
    private struct Page { let id: UUID; let back: DismissAction }
    @Published private var pages: [Page] = []

    var canGoBack: Bool { !pages.isEmpty }

    func appeared(_ id: UUID, back: DismissAction) {
        guard !pages.contains(where: { $0.id == id }) else { return }
        pages.append(Page(id: id, back: back))
    }

    func disappeared(_ id: UUID) {
        pages.removeAll { $0.id == id }
    }

    func goBack() {
        pages.last?.back()
    }
}

extension EnvironmentValues {
    /// The navigator of the Mac section a view is in (nil outside the main window's sections).
    @Entry var macNavigator: MacNavigator? = nil
    /// How far the floating window controls reach down the window; page titles start below it.
    @Entry var macChromeInset: CGFloat = 0
}
#endif
