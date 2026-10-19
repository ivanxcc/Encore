import SwiftUI

extension View {
    /// Liquid Glass on iOS, tvOS, and macOS 26 (when built with Xcode 26), and the closest material
    /// before that, so the same view reads as glass everywhere it can and as frosted glass elsewhere.
    @ViewBuilder func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            self.glassEffect(encoreGlass(tint: tint), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
private func encoreGlass(tint: Color?) -> Glass {
    tint.map { Glass.regular.tint($0) } ?? .regular
}
#endif
