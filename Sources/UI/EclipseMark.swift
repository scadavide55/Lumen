import SwiftUI

/// Lumen's mark, the "Eclissi" of the app icon: a dark disc over a sun, leaving a crescent of light.
/// `glow` (0…1) brightens the halo, for a gentle pulse.
struct EclipseMark: View {
    var size: CGFloat
    var glow: Double = 0

    static let sun = LinearGradient(colors: [Color(red: 1, green: 0.76, blue: 0.29), Color(red: 1, green: 0.35, blue: 0.16)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let coral = Color(red: 1, green: 0.48, blue: 0.23)

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Self.coral.opacity(0.4 + 0.25 * glow), Self.coral.opacity(0)],
                                     center: .center, startRadius: size * 0.5, endRadius: size * 0.72))
                .frame(width: size * 1.43, height: size * 1.43)
            Circle().fill(Self.sun).frame(width: size, height: size)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.23, green: 0.22, blue: 0.32), Color(red: 0.08, green: 0.07, blue: 0.11)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.9))
                .frame(width: size, height: size)
                .offset(x: -size * 0.15, y: size * 0.133)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
