import Foundation

enum DepthPreset: String, Codable, CaseIterable, Identifiable {
    case natural, foreground, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: "自然"
        case .foreground: "突出前景"
        case .custom: "自定义"
        }
    }
}

struct DepthEffect: Codable, Equatable {
    let strength: Float
    let popOut: Float
    let proportionProtection: Bool
    let preset: DepthPreset

    static let natural = DepthEffect(strength: 0.35, popOut: 0, proportionProtection: true)
    static let foreground = DepthEffect(strength: 0.35, popOut: 0.6, proportionProtection: true)

    init(strength: Float, popOut: Float, proportionProtection: Bool, preset: DepthPreset? = nil) {
        self.strength = strength.isFinite ? min(1, max(0, strength)) : 0.35
        self.popOut = popOut.isFinite ? min(1, max(0, popOut)) : 0
        self.proportionProtection = proportionProtection
        if preset == .custom {
            self.preset = .custom
        } else if self.strength == 0.35 && proportionProtection && self.popOut == 0 {
            self.preset = .natural
        } else if self.strength == 0.35 && proportionProtection && self.popOut == 0.6 {
            self.preset = .foreground
        } else {
            self.preset = .custom
        }
    }

    var normalized: DepthEffect {
        DepthEffect(strength: strength, popOut: popOut, proportionProtection: proportionProtection, preset: preset)
    }
}
