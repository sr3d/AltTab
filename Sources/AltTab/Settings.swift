import Foundation

/// User preferences, stored in UserDefaults (com.sr3d.AltTab).
enum Settings {
    static let fontSizeRange: ClosedRange<Double> = 11...28
    static let defaultFontSize: Double = 14
    /// Temporary size that doesn't touch saved preferences (used by screenshot rendering).
    static var fontSizeOverride: CGFloat?

    /// Point size for the switcher list; rows, icons and the filter bar scale with it.
    static var fontSize: CGFloat {
        get {
            if let fontSizeOverride { return fontSizeOverride }
            let stored = UserDefaults.standard.double(forKey: "fontSize")
            return CGFloat(stored == 0 ? defaultFontSize : min(max(stored, fontSizeRange.lowerBound), fontSizeRange.upperBound))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "fontSize") }
    }
}
