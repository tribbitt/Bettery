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
        static let fillChargingParty   = "fillChargingParty"
        static let fillStandardParty   = "fillStandardParty"
        static let fillSaverParty      = "fillSaverParty"
        static let fillLowBatteryParty = "fillLowBatteryParty"
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
    static let defaultFillParty: Bool = false

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
    // Per-state Party Mode flags. When the icon's current fill state has its
    // flag on, the fill (or smiley if fill is disabled) cycles through the
    // precomputed rainbow LUT instead of using its static color.
    @Published var fillChargingParty: Bool     { didSet { defaults.set(fillChargingParty,      forKey: Keys.fillChargingParty) } }
    @Published var fillStandardParty: Bool     { didSet { defaults.set(fillStandardParty,      forKey: Keys.fillStandardParty) } }
    @Published var fillSaverParty: Bool        { didSet { defaults.set(fillSaverParty,         forKey: Keys.fillSaverParty) } }
    @Published var fillLowBatteryParty: Bool   { didSet { defaults.set(fillLowBatteryParty,    forKey: Keys.fillLowBatteryParty) } }

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
            Keys.fillChargingParty:     Self.defaultFillParty,
            Keys.fillStandardParty:     Self.defaultFillParty,
            Keys.fillSaverParty:        Self.defaultFillParty,
            Keys.fillLowBatteryParty:   Self.defaultFillParty
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
        self.fillChargingParty    = defaults.bool(forKey: Keys.fillChargingParty)
        self.fillStandardParty    = defaults.bool(forKey: Keys.fillStandardParty)
        self.fillSaverParty       = defaults.bool(forKey: Keys.fillSaverParty)
        self.fillLowBatteryParty  = defaults.bool(forKey: Keys.fillLowBatteryParty)
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
        fillChargingParty   = Self.defaultFillParty
        fillStandardParty   = Self.defaultFillParty
        fillSaverParty      = Self.defaultFillParty
        fillLowBatteryParty = Self.defaultFillParty
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

// MARK: - Slot-keyed bindings
// Used so views can ForEach over FillSlot.allCases without each row
// hand-naming the field. FillSlot itself is defined in Views.swift so it
// can be referenced from SwiftUI and AppKit code uniformly.

extension Settings {
    func fillColor(for slot: FillSlot) -> Binding<Color> {
        switch slot {
        case .charging:   return Binding(get: { self.fillChargingColor },   set: { self.fillChargingColor = $0 })
        case .standard:   return Binding(get: { self.fillStandardColor },   set: { self.fillStandardColor = $0 })
        case .saver:      return Binding(get: { self.fillSaverColor },      set: { self.fillSaverColor = $0 })
        case .lowBattery: return Binding(get: { self.fillLowBatteryColor }, set: { self.fillLowBatteryColor = $0 })
        }
    }
    func partyFlag(for slot: FillSlot) -> Binding<Bool> {
        switch slot {
        case .charging:   return Binding(get: { self.fillChargingParty },   set: { self.fillChargingParty = $0 })
        case .standard:   return Binding(get: { self.fillStandardParty },   set: { self.fillStandardParty = $0 })
        case .saver:      return Binding(get: { self.fillSaverParty },      set: { self.fillSaverParty = $0 })
        case .lowBattery: return Binding(get: { self.fillLowBatteryParty }, set: { self.fillLowBatteryParty = $0 })
        }
    }
    /// Read-only for the icon renderer's hot path — avoids Binding overhead.
    func isParty(for slot: FillSlot) -> Bool {
        switch slot {
        case .charging:   return fillChargingParty
        case .standard:   return fillStandardParty
        case .saver:      return fillSaverParty
        case .lowBattery: return fillLowBatteryParty
        }
    }
}
