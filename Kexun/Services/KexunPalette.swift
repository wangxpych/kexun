import UIKit

@MainActor
enum KexunPalette {
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.43, green: 0.79, blue: 0.67, alpha: 1)
            : UIColor(red: 0.06, green: 0.40, blue: 0.35, alpha: 1)
    }
    static let page = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.06, green: 0.08, blue: 0.07, alpha: 1)
            : UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
    }
    static let onAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    }
}
