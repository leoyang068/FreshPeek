import SwiftUI

enum FridgeTheme {
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
    static let paperDeep = Color(red: 0.91, green: 0.88, blue: 0.80)
    static let ink = Color(red: 0.24, green: 0.25, blue: 0.23)
    static let mutedInk = Color(red: 0.44, green: 0.45, blue: 0.41)
    static let fridgeBody = Color(red: 0.83, green: 0.90, blue: 0.89)
    static let fridgeInside = Color(red: 0.94, green: 0.97, blue: 0.95)
    static let expired = Color(red: 0.83, green: 0.57, blue: 0.55)
    static let expiring = Color(red: 0.91, green: 0.71, blue: 0.48)
    static let fresh = Color(red: 0.62, green: 0.76, blue: 0.61)
    static let accent = Color(red: 0.35, green: 0.57, blue: 0.51)

    static func color(for state: ExpiryState) -> Color {
        switch state {
        case .expired: expired
        case .expiringSoon: expiring
        case .fresh: fresh
        }
    }

}

struct PaperTexture: View {
    var body: some View {
        ZStack {
            FridgeTheme.paper
            Canvas { context, size in
                for index in 0..<55 {
                    let x = CGFloat((index * 47) % 101) / 101 * size.width
                    let y = CGFloat((index * 83) % 103) / 103 * size.height
                    let dot = Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3))
                    context.fill(dot, with: .color(FridgeTheme.paperDeep.opacity(0.32)))
                }
            }
        }
        .ignoresSafeArea()
    }
}
