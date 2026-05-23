import Foundation
import SwiftUI
import AppKit
import Combine

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cpuOn = "saverOnAtCPU"
        static let gpuOn = "saverOnAtGPU"
        static let cpuOff = "saverOffAtCPU"
        static let gpuOff = "saverOffAtGPU"
        static let battOn = "saverOnAtBatt"
        static let saverWhileCharging = "saverOnWhileCharging"
        static let iconStyle = "iconStyle"
        static let graphStandard = "graphStandardColorData"
        static let graphSleep = "graphSleepColorData"
        static let graphSaver = "graphSaverColorData"
        static let graphCharging = "graphChargingColorData"
        static let fillCharging = "fillChargingColorData"
        static let fillStandard = "fillStandardColorData"
        static let fillSaver = "fillSaverColorData"
        static let fillLowBatt = "fillLowBatteryColorData"
        static let fontFamily = "fontFamily"
        static let contrastySmiley = "contrastySmiley"
        static let enableFill = "enableFill"
        static let enableSmiley = "enableSmiley"
        static let autoBoost = "autoBoost"
        static let notificationsEnabled = "notificationsEnabled"
        static let showPercentage = "showPercentage"
        static let partyMode = "partyMode"
    }

    // MARK: - Defaults (constants used by both register-step and restore-buttons)

    static let defaultCPUOn: Double = 90
    static let defaultGPUOn: Double = 90
    static let defaultCPUOff: Double = 90
    static let defaultGPUOff: Double = 90
    static let defaultBattOn: Double = 25
    static let defaultSaverWhileCharging: Bool = false
    static let defaultFontFamily: String = "system"
    static let defaultContrastySmiley: Bool = false
    static let defaultEnableFill: Bool = true
    static let defaultEnableSmiley: Bool = true
    static let defaultAutoBoost: Bool = true
    static let defaultNotificationsEnabled: Bool = true
    static let defaultShowPercentage: Bool = true
    static let defaultPartyMode: Bool = false

    // Defaults match the previously hardcoded colors in BatteryGraphView.
    static let defaultStandardColor: Color = .white
    static let defaultSleepColor: Color    = Color(white: 0.45)
    static let defaultSaverColor: Color    = Color(red: 0.92, green: 0.74, blue: 0.10)
    static let defaultChargingColor: Color = Color(red: 0.10, green: 0.80, blue: 0.20)

    // Menu bar fill defaults — same palette as the graph for visual consistency.
    static let defaultFillCharging:   Color = Color(red: 0.10, green: 0.80, blue: 0.20)
    // Medium-light gray — contrasts with the white smiley on the PNG so the
    // design stays visible. White would render the smiley invisible.
    static let defaultFillStandard:   Color = Color(white: 0.65)
    static let defaultFillSaver:      Color = Color(red: 0.92, green: 0.74, blue: 0.10)
    static let defaultFillLowBattery: Color = Color(red: 0.94, green: 0.16, blue: 0.16)

    // MARK: - Threshold settings

    @Published var saverOnAtCPU: Double { didSet { defaults.set(saverOnAtCPU, forKey: Keys.cpuOn) } }
    @Published var saverOnAtGPU: Double { didSet { defaults.set(saverOnAtGPU, forKey: Keys.gpuOn) } }
    @Published var saverOffAtCPU: Double { didSet { defaults.set(saverOffAtCPU, forKey: Keys.cpuOff) } }
    @Published var saverOffAtGPU: Double { didSet { defaults.set(saverOffAtGPU, forKey: Keys.gpuOff) } }
    @Published var saverOnAtBatt: Double { didSet { defaults.set(saverOnAtBatt, forKey: Keys.battOn) } }
    @Published var saverOnWhileCharging: Bool { didSet { defaults.set(saverOnWhileCharging, forKey: Keys.saverWhileCharging) } }
    @Published var iconStyle: String { didSet { defaults.set(iconStyle, forKey: Keys.iconStyle) } }

    // MARK: - Appearance settings

    @Published var graphStandardColor: Color { didSet { defaults.set(Self.encode(graphStandardColor), forKey: Keys.graphStandard) } }
    @Published var graphSleepColor: Color    { didSet { defaults.set(Self.encode(graphSleepColor),    forKey: Keys.graphSleep) } }
    @Published var graphSaverColor: Color    { didSet { defaults.set(Self.encode(graphSaverColor),    forKey: Keys.graphSaver) } }
    @Published var graphChargingColor: Color { didSet { defaults.set(Self.encode(graphChargingColor), forKey: Keys.graphCharging) } }
    @Published var fillChargingColor: Color   { didSet { defaults.set(Self.encode(fillChargingColor),   forKey: Keys.fillCharging) } }
    @Published var fillStandardColor: Color   { didSet { defaults.set(Self.encode(fillStandardColor),   forKey: Keys.fillStandard) } }
    @Published var fillSaverColor: Color      { didSet { defaults.set(Self.encode(fillSaverColor),      forKey: Keys.fillSaver) } }
    @Published var fillLowBatteryColor: Color { didSet { defaults.set(Self.encode(fillLowBatteryColor), forKey: Keys.fillLowBatt) } }
    @Published var fontFamily: String         { didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) } }
    @Published var contrastySmiley: Bool      { didSet { defaults.set(contrastySmiley, forKey: Keys.contrastySmiley) } }
    @Published var enableFill: Bool           { didSet { defaults.set(enableFill, forKey: Keys.enableFill) } }
    @Published var enableSmiley: Bool         { didSet { defaults.set(enableSmiley,     forKey: Keys.enableSmiley) } }
    @Published var autoBoost: Bool             { didSet { defaults.set(autoBoost,             forKey: Keys.autoBoost) } }
    @Published var notificationsEnabled: Bool  { didSet { defaults.set(notificationsEnabled,  forKey: Keys.notificationsEnabled) } }
    @Published var showPercentage: Bool        { didSet { defaults.set(showPercentage,         forKey: Keys.showPercentage) } }
    @Published var partyMode: Bool             { didSet { defaults.set(partyMode,              forKey: Keys.partyMode) } }

    private init() {
        defaults.register(defaults: [
            Keys.cpuOn: Self.defaultCPUOn,
            Keys.gpuOn: Self.defaultGPUOn,
            Keys.cpuOff: Self.defaultCPUOff,
            Keys.gpuOff: Self.defaultGPUOff,
            Keys.battOn: Self.defaultBattOn,
            Keys.saverWhileCharging: Self.defaultSaverWhileCharging,
            Keys.iconStyle: "black",
            Keys.fontFamily: Self.defaultFontFamily,
            Keys.contrastySmiley: Self.defaultContrastySmiley,
            Keys.enableFill: Self.defaultEnableFill,
            Keys.enableSmiley:    Self.defaultEnableSmiley,
            Keys.autoBoost:             Self.defaultAutoBoost,
            Keys.notificationsEnabled:  Self.defaultNotificationsEnabled,
            Keys.showPercentage:        Self.defaultShowPercentage,
            Keys.partyMode:             Self.defaultPartyMode
            Keys.showPercentage:        Self.defaultShowPercentage
        ])
        self.saverOnAtCPU         = defaults.double(forKey: Keys.cpuOn)
        self.saverOnAtGPU         = defaults.double(forKey: Keys.gpuOn)
        self.saverOffAtCPU        = defaults.double(forKey: Keys.cpuOff)
        self.saverOffAtGPU        = defaults.double(forKey: Keys.gpuOff)
        self.saverOnAtBatt        = defaults.double(forKey: Keys.battOn)
        self.saverOnWhileCharging = defaults.bool(forKey: Keys.saverWhileCharging)
        self.iconStyle            = defaults.string(forKey: Keys.iconStyle) ?? "black"
        self.fontFamily           = defaults.string(forKey: Keys.fontFamily) ?? Self.defaultFontFamily
        self.graphStandardColor   = Self.decode(defaults.data(forKey: Keys.graphStandard), fallback: Self.defaultStandardColor)
        self.graphSleepColor      = Self.decode(defaults.data(forKey: Keys.graphSleep),    fallback: Self.defaultSleepColor)
        self.graphSaverColor      = Self.decode(defaults.data(forKey: Keys.graphSaver),    fallback: Self.defaultSaverColor)
        self.graphChargingColor   = Self.decode(defaults.data(forKey: Keys.graphCharging), fallback: Self.defaultChargingColor)
        self.fillChargingColor    = Self.decode(defaults.data(forKey: Keys.fillCharging),  fallback: Self.defaultFillCharging)
        self.fillStandardColor    = Self.decode(defaults.data(forKey: Keys.fillStandard),  fallback: Self.defaultFillStandard)
        self.fillSaverColor       = Self.decode(defaults.data(forKey: Keys.fillSaver),     fallback: Self.defaultFillSaver)
        self.fillLowBatteryColor  = Self.decode(defaults.data(forKey: Keys.fillLowBatt),   fallback: Self.defaultFillLowBattery)
        self.contrastySmiley      = defaults.bool(forKey: Keys.contrastySmiley)
        self.enableFill           = defaults.bool(forKey: Keys.enableFill)
        self.enableSmiley         = defaults.bool(forKey: Keys.enableSmiley)
        self.autoBoost            = defaults.bool(forKey: Keys.autoBoost)
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.showPercentage       = defaults.bool(forKey: Keys.showPercentage)
        self.partyMode            = defaults.bool(forKey: Keys.partyMode)
    }

    // MARK: - Restore

    func restoreDefaultColors() {
        graphStandardColor  = Self.defaultStandardColor
        graphSleepColor     = Self.defaultSleepColor
        graphSaverColor     = Self.defaultSaverColor
        graphChargingColor  = Self.defaultChargingColor
        fillChargingColor   = Self.defaultFillCharging
        fillStandardColor   = Self.defaultFillStandard
        fillSaverColor      = Self.defaultFillSaver
        fillLowBatteryColor = Self.defaultFillLowBattery
        fontFamily          = Self.defaultFontFamily
        contrastySmiley     = Self.defaultContrastySmiley
        enableFill          = Self.defaultEnableFill
    }

    func restoreDefaultSettings() {
        saverOnAtCPU         = Self.defaultCPUOn
        saverOnAtGPU         = Self.defaultGPUOn
        saverOffAtCPU        = Self.defaultCPUOff
        saverOffAtGPU        = Self.defaultGPUOff
        saverOnAtBatt        = Self.defaultBattOn
        saverOnWhileCharging = Self.defaultSaverWhileCharging
        restoreDefaultColors()
    }

    // MARK: - SwiftUI Font helper

    /// Returns a Font for the user's chosen family. The four leading tags map
    /// onto Font.Design variants of the system font (so weight is respected);
    /// anything else is treated as an installed font family name from
    /// NSFontManager and rendered via Font.custom (weight is ignored for those —
    /// custom fonts pick their own weights via face names).
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch fontFamily {
        case "system":     return .system(size: size, weight: weight, design: .default)
        case "rounded":    return .system(size: size, weight: weight, design: .rounded)
        case "monospaced": return .system(size: size, weight: weight, design: .monospaced)
        case "serif":      return .system(size: size, weight: weight, design: .serif)
        default:           return .custom(fontFamily, size: size)
        }
    }

    // MARK: - Color persistence
    //
    // SwiftUI Color isn't directly Codable. Round-trip via NSColor + NSKeyedArchiver
    // — preserves any color space the user picked in NSColorPanel.

    private static func encode(_ color: Color) -> Data {
        let ns = NSColor(color)
        return (try? NSKeyedArchiver.archivedData(withRootObject: ns, requiringSecureCoding: true)) ?? Data()
    }

    private static func decode(_ data: Data?, fallback: Color) -> Color {
        guard let data,
              let ns = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        else { return fallback }
        return Color(nsColor: ns)
    }
}
