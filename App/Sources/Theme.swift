import SwiftUI

/// Dark navy + electric blue design language used across the app.
enum Theme {
    static let bg = Color(red: 0.043, green: 0.055, blue: 0.09)          // near-black navy
    static let card = Color(red: 0.078, green: 0.094, blue: 0.145)       // raised card
    static let cardInner = Color(red: 0.11, green: 0.133, blue: 0.196)   // nested surface
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.18, green: 0.52, blue: 1.0)
    static let textSecondary = Color.white.opacity(0.55)

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.25, green: 0.6, blue: 1.0), Color(red: 0.05, green: 0.38, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let uiBg = UIColor(red: 0.043, green: 0.055, blue: 0.09, alpha: 1)
}

struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.45), radius: size * 0.2, y: 3)
    }
}

extension View {
    /// Applies the dark app background behind a List/Form/ScrollView.
    func darkListBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg)
    }
}
