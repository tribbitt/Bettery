import SwiftUI
import AppKit

// MARK: - Battery graph: continuous area chart, colored by battery state.
//
// The graph is a filled area whose color tracks the battery's mode at each
// moment (charging / saver / normal). Consecutive samples with the same
// state are merged into a single Path so each color region is one draw call
// and color transitions land precisely at the sample where the mode changed.

struct BatteryGraphView: View {
    @ObservedObject var history: BatteryHistory
    @ObservedObject var settings: Settings

    private let windowDuration: TimeInterval = 24 * 3600   // 24-hour sliding window

    var body: some View {
        let now         = Date()
        let windowStart = now.addingTimeInterval(-windowDuration)

        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let segs = segments(width: geo.size.width, height: geo.size.height,
                                    windowStart: windowStart, now: now)
                ZStack(alignment: .bottom) {
                    // Horizontal grid at 25 / 50 / 75 %
                    ForEach([0.25, 0.50, 0.75], id: \.self) { frac in
                        let y = geo.size.height * CGFloat(1.0 - frac)
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.15),
                                style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    }
                    // Filled area, one path per merged same-color run.
                    ForEach(segs.indices, id: \.self) { i in
                        segs[i].path.fill(segs[i].color)
                    }
                    // Specular highlight along the data line — the "wet" top edge
                    // that sells the glass effect. Sleep segments are excluded
                    // because the gray overlay below would clash with it.
                    Canvas { ctx, size in
                        for seg in segs where !seg.isSleep {
                            ctx.stroke(seg.topEdge,
                                       with: .color(Color.white.opacity(0.55)),
                                       style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
                        }
                    }
                    // Awake macOS-history segments: gray crosshatch overlay,
                    // clipped to each polygon so the pattern follows the data line.
                    Canvas { ctx, size in
                        for seg in segs where seg.crosshatched && !seg.isSleep {
                            ctx.drawLayer { layer in
                                layer.clip(to: seg.path)
                                drawDiagonalHatch(in: &layer, size: size,
                                                  color: Color(white: 0.2),
                                                  opacity: 0.55,
                                                  lineWidth: 0.8)
                            }
                        }
                    }
                    // Sleep segments: user-picked gray fill + thin white diagonal lines,
                    // all clipped to the polygon shape — so the pattern stops
                    // at the data line instead of running full chart height.
                    Canvas { ctx, size in
                        for seg in segs where seg.isSleep {
                            ctx.fill(seg.path, with: .color(settings.graphSleepColor.opacity(0.9)))
                            ctx.drawLayer { layer in
                                layer.clip(to: seg.path)
                                drawDiagonalHatch(in: &layer, size: size,
                                                  color: .white,
                                                  opacity: 0.95,
                                                  lineWidth: 0.6)
                            }
                        }
                    }
                }
                .background(Color.primary.opacity(0.04))
            }
            .frame(height: 64)

            GeometryReader { geo in
                xAxisCanvas(width: geo.size.width, windowStart: windowStart, now: now)
            }
            .frame(height: 12)
        }
    }

    // MARK: - Segment computation

    private struct Segment {
        let color: Color
        let crosshatched: Bool      // true when ≥1 endpoint is a pmset event (macOS history)
        let isSleep: Bool           // true when the segment's midpoint falls inside a sleep interval
        let path: Path
        let topEdge: Path           // just the data-line portion, used for the glass highlight
    }

    /// Live samples spaced 5 sec apart should never have a gap this large unless
    /// the system itself went down — used as a fallback sleep detector when
    /// pmset's explicit Sleep/Wake events are missing (e.g., aged out of the
    /// log, or crash-truncated). Explicit pmset sleep is preferred.
    private let liveGapSleepThreshold: TimeInterval = 30 * 60

    private func segments(width: CGFloat, height: CGFloat,
                          windowStart: Date, now: Date) -> [Segment] {
        let samples = history.samples
        guard !samples.isEmpty else { return [] }

        let xFor: (Date)   -> CGFloat = { CGFloat($0.timeIntervalSince(windowStart) / windowDuration) * width }
        let yFor: (Double) -> CGFloat = { (1 - CGFloat($0 / 100.0)) * height }

        let sleepIntervals = combinedSleepIntervals(samples: samples)
        func isSleepAt(_ t: Date) -> Bool {
            sleepIntervals.contains { $0.start <= t && t < $0.end }
        }

        // Each link is classified by (color, crosshatched, isSleep). A run merges
        // consecutive same-classification links into one polygon — eliminates
        // anti-aliasing seams between adjacent independently-filled trapezoids.
        struct Run {
            let color: Color
            let crosshatched: Bool
            let isSleep: Bool
            var first: Int
            var last: Int
        }
        var runs: [Run] = []
        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            // Midpoint classification: the segment is sleep if its center lies
            // inside a sleep interval. Avoids splitting tiny boundary slivers.
            let midEpoch = (a.timestamp.timeIntervalSince1970 + b.timestamp.timeIntervalSince1970) / 2
            let mid = Date(timeIntervalSince1970: midEpoch)
            let segIsSleep = isSleepAt(mid)
            // Crosshatch overlay applies to awake pmset segments only — sleep
            // segments get their own (white) overlay and shouldn't double-stack.
            let segCrosshatched = !segIsSleep && (a.source == .event || b.source == .event)
            // Historical (pmset) segments don't know which mode the user was in,
            // so color by battery delta: rising = charging green, flat/falling = normal white.
            // Live segments retain the recorded state's color.
            let segColor: Color = segCrosshatched
                ? (b.percentage > a.percentage ? chargingColor : normalColor)
                : stateColor(a.state)
            if !runs.isEmpty,
               runs[runs.count - 1].color == segColor,
               runs[runs.count - 1].crosshatched == segCrosshatched,
               runs[runs.count - 1].isSleep == segIsSleep,
               runs[runs.count - 1].last == i {
                runs[runs.count - 1].last = i + 1
            } else {
                runs.append(Run(color: segColor,
                                crosshatched: segCrosshatched,
                                isSleep: segIsSleep,
                                first: i, last: i + 1))
            }
        }

        var out: [Segment] = []
        for run in runs {
            let pts: [CGPoint] = (run.first...run.last).map {
                CGPoint(x: xFor(samples[$0].timestamp), y: yFor(samples[$0].percentage))
            }
            guard pts.count >= 2 else { continue }
            var path = Path()
            var top = Path()
            path.move(to: CGPoint(x: pts.first!.x, y: height))
            for (idx, p) in pts.enumerated() {
                path.addLine(to: p)
                if idx == 0 { top.move(to: p) } else { top.addLine(to: p) }
            }
            path.addLine(to: CGPoint(x: pts.last!.x, y: height))
            path.closeSubpath()
            out.append(Segment(color: run.color,
                               crosshatched: run.crosshatched,
                               isSleep: run.isSleep,
                               path: path, topEdge: top))
        }
        // Final segment: extend the most recent sample horizontally to "now".
        if let last = samples.last {
            let lastX = xFor(last.timestamp)
            let nowX = xFor(now)
            if lastX < nowX {
                let y = yFor(last.percentage)
                var path = Path()
                path.move(to: CGPoint(x: lastX, y: height))
                path.addLine(to: CGPoint(x: lastX, y: y))
                path.addLine(to: CGPoint(x: nowX, y: y))
                path.addLine(to: CGPoint(x: nowX, y: height))
                path.closeSubpath()
                var top = Path()
                top.move(to: CGPoint(x: lastX, y: y))
                top.addLine(to: CGPoint(x: nowX, y: y))
                out.append(Segment(color: stateColor(last.state),
                                   crosshatched: last.source == .event,
                                   isSleep: false,
                                   path: path, topEdge: top))
            }
        }
        return out
    }

    /// Combines pmset's explicit Sleep → Wake intervals with a heuristic
    /// fallback: any live-to-live gap over 30 min. Our 5-sec timer can only
    /// stop firing if the system itself went down, so such a gap is real sleep
    /// even when pmset's explicit events have aged off the log tail.
    private func combinedSleepIntervals(samples: [BatterySample]) -> [SleepInterval] {
        var intervals: [SleepInterval] = history.sleepIntervals
        var lastLive: Date? = nil
        for s in samples where s.source == .live {
            if let prev = lastLive,
               s.timestamp.timeIntervalSince(prev) > liveGapSleepThreshold {
                intervals.append(SleepInterval(start: prev, end: s.timestamp))
            }
            lastLive = s.timestamp
        }
        return intervals
    }

    /// Diagonal hatch lines running bottom-left → top-right (slope −1 in
    /// screen coords). Each line is parallel; perpendicular spacing is ~6px.
    /// The caller is expected to have clipped the context to the target shape.
    private func drawDiagonalHatch(in ctx: inout GraphicsContext, size: CGSize,
                                    color: Color, opacity: Double, lineWidth: CGFloat) {
        let spacing: CGFloat = 6
        let step = spacing * sqrt(2)
        let style = StrokeStyle(lineWidth: lineWidth)
        // c = the line's x-coordinate at the bottom edge; line ends at (c + H, 0).
        // Range from −H (line ends at origin) to W (line starts at top-right corner).
        var c: CGFloat = -size.height
        while c <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: c, y: size.height))
            line.addLine(to: CGPoint(x: c + size.height, y: 0))
            ctx.stroke(line, with: .color(color.opacity(opacity)), style: style)
            c += step
        }
    }

    // MARK: - Colors
    // All four pull from Settings so the Appearance pickers take effect.
    private var chargingColor: Color { settings.graphChargingColor }
    private var saverColor:    Color { settings.graphSaverColor }
    private var normalColor:   Color { settings.graphStandardColor }

    private func stateColor(_ state: BatteryState) -> Color {
        switch state {
        case .charging: return chargingColor
        case .saverOn:  return saverColor
        case .saverOff: return normalColor
        }
    }

    // Cached once — DateFormatter allocation is not free, and the format is
    // fixed ("HH" — 24-hour) so there's no reason to rebuild it per render.
    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH"
        f.locale = Locale.current
        return f
    }()

    /// Draws x-axis hour labels using Canvas for pixel-exact placement.
    private func xAxisCanvas(width: CGFloat, windowStart: Date, now: Date) -> some View {
        let ticks = hourTicks(windowStart: windowStart, now: now)
        let fmt   = Self.hourFormatter
        return Canvas { ctx, size in
            for tick in ticks {
                let frac     = CGFloat(tick.timeIntervalSince(windowStart) / windowDuration)
                let x        = frac * size.width
                let resolved = ctx.resolve(
                    Text(fmt.string(from: tick))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                )
                // Center-anchor by default so the label sits visually at its actual
                // time. Only shift to edge-anchor when the label would clip off the
                // window — i.e., when it's within ~3% (≈14 min) of either edge.
                let anchor: UnitPoint
                if      frac < 0.03 { anchor = .topLeading  }
                else if frac > 0.97 { anchor = .topTrailing }
                else                { anchor = .top         }
                ctx.draw(resolved, at: CGPoint(x: x, y: 0), anchor: anchor)
            }
        }
    }

    /// Hour ticks every 4 hours strictly inside the 24-hour window.
    /// At ~256px of usable width, hourly ticks would overlap; every-4h yields
    /// 5–6 well-spaced labels (00, 04, 08, 12, 16, 20). The right edge is left
    /// unlabelled so it slides naturally with "now."
    private func hourTicks(windowStart: Date, now: Date) -> [Date] {
        let cal = Calendar.current
        guard var t = cal.nextDate(after: windowStart,
                                   matching: DateComponents(minute: 0, second: 0),
                                   matchingPolicy: .nextTime) else { return [] }
        var ticks: [Date] = []
        while t < now {
            if cal.component(.hour, from: t) % 4 == 0 {
                ticks.append(t)
            }
            t = t.addingTimeInterval(3600)
        }
        return ticks
    }

}

// MARK: - Options rows

struct OptionsView: View {
    @ObservedObject var settings: Settings

    @State private var showThresholds = false
    @State private var showAppearance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            toggleRow(label: "Auto-Boost Performance", value: $settings.autoBoost)
                .padding(.vertical, 4)

            if settings.autoBoost {
                sectionHeader(label: "Toggle Thresholds", expanded: $showThresholds)
                if showThresholds {
                    VStack(alignment: .leading, spacing: 0) {
                        settingRow(label: "Saver Off at CPU",     value: $settings.saverOffAtCPU)
                        settingRow(label: "Saver Off at GPU",     value: $settings.saverOffAtGPU)
                        settingRow(label: "Saver On at CPU",      value: $settings.saverOnAtCPU)
                        settingRow(label: "Saver On at GPU",      value: $settings.saverOnAtGPU)
                        Divider().padding(.vertical, 4)
                        settingRow(label: "Saver On at Battery",  value: $settings.saverOnAtBatt)
                        Divider().padding(.vertical, 4)
                        toggleRow(label: "Saver On When Charging", value: $settings.saverOnWhileCharging)
                    }
                    .padding(.leading, 10)
                    .padding(.bottom, 4)
                }
            }

            Divider()

            sectionHeader(label: "Appearance", expanded: $showAppearance)
            if showAppearance {
                VStack(alignment: .leading, spacing: 8) {
                    groupLabel("Graph Colors")
                    colorRow(label: "Charging",       binding: $settings.graphChargingColor)
                    colorRow(label: "Normal",         binding: $settings.graphStandardColor)
                    colorRow(label: "Low-Power Mode", binding: $settings.graphSaverColor)
                    colorRow(label: "Sleep",          binding: $settings.graphSleepColor)

                    groupLabel("Icon Fill")
                        .padding(.top, 4)
                    toggleRow(label: "Fill",          value: $settings.enableFill)
                    if settings.enableFill {
                        colorRow(label: "Charging",       binding: $settings.fillChargingColor)
                        colorRow(label: "Normal",         binding: $settings.fillStandardColor)
                        colorRow(label: "Low-Power Mode", binding: $settings.fillSaverColor)
                        colorRow(label: "Low-Battery",    binding: $settings.fillLowBatteryColor)
                    }

                    fontRow().padding(.top, 4)
                    toggleRow(label: "Battery Percentage", value: $settings.showPercentage)
                    toggleRow(label: "Smiley",             value: $settings.enableSmiley)
                    if settings.enableSmiley {
                        toggleRow(label: "Contrast Smiley", value: $settings.contrastySmiley)
                    }
                    Button("Restore Default Colors") {
                        settings.restoreDefaultColors()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                .padding(.leading, 10)
                .padding(.vertical, 6)
            }

            Divider()

            // Battery Settings — opens the system Battery preferences pane.
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("System Battery Settings")
                    .font(settings.font(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 4)

            Button("Restore Default Settings") {
                settings.restoreDefaultSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // Header row with chevron — mirrors the style of the outer Options toggle so
    // nested sub-lists feel native rather than DisclosureGroup-formal.
    private func sectionHeader(label: String, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            HStack {
                Text(label).font(settings.font(size: 12, weight: .medium))
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func settingRow(label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(settings.font(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .font(settings.font(size: 12))
            Text("%")
                .font(settings.font(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 14)
        }
        .padding(.vertical, 5)
    }

    private func toggleRow(label: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(settings.font(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: value)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 5)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(settings.font(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private func colorRow(label: String, binding: Binding<Color>) -> some View {
        HStack {
            Text(label)
                .font(settings.font(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
        }
    }

    // Cached once — enumerating installed fonts isn't free, and the list is
    // stable for the app's lifetime. Sorted for stable picker order.
    private static let installedFontFamilies: [String] = NSFontManager.shared
        .availableFontFamilies
        .sorted()

    private func fontRow() -> some View {
        HStack {
            Text("Font")
                .font(settings.font(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: $settings.fontFamily) {
                Text("System").tag("system")
                Text("Rounded").tag("rounded")
                Text("Monospaced").tag("monospaced")
                Text("Serif").tag("serif")
                Divider()
                ForEach(Self.installedFontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 120)
        }
    }
}

// MARK: - Reusable menu row highlight

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                : Color.clear)
    }
}

// MARK: - Main menu

struct MainMenuView: View {
    @ObservedObject var history: BatteryHistory
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    var onQuit: () -> Void
    var onToggle: (Bool) -> Void
    var onInstallSudoers: () -> Bool = { false }

    @State private var showOptions = false
    @State private var sudoersInstalled: Bool = BatteryManager.sudoersInstalled()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            BatteryGraphView(history: history, settings: settings)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Divider()

            // Prominent setup banner — sudo toggles prompt for password every time
            // until this is installed, so we surface it at the top, not behind a dropdown.
            if !sudoersInstalled {
                Button {
                    if onInstallSudoers() { sudoersInstalled = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Enable Passwordless Toggling")
                            .font(settings.font(size: 12, weight: .medium))
                        Spacer()
                        Text("One-Time")
                            .font(settings.font(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                }
                .buttonStyle(.plain)
                Divider()
            }

            // Power source — read-only status row
            HStack {
                Text("Power Source")
                    .font(settings.font(size: 13))
                Spacer()
                Text(state.powerSource)
                    .font(settings.font(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            // Apps using significant energy — list of icons + names, or fallback.
            // When empty, the fallback line is self-describing — header would be redundant.
            VStack(alignment: .leading, spacing: 6) {
                if state.significantApps.isEmpty {
                    Text("No Apps Using Significant Energy")
                        .font(settings.font(size: 13))
                } else {
                    Text("Apps Using Significant Energy")
                        .font(settings.font(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    ForEach(state.significantApps, id: \.pid) { app in
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                // Keep alignment consistent when an app has no icon.
                                Color.clear.frame(width: 16, height: 16)
                            }
                            Text(app.name)
                                .font(settings.font(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Button("Close") { closeOrReveal(app) }
                                .font(settings.font(size: 11))
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Options — full-width tap target
            Button {
                showOptions.toggle()
            } label: {
                HStack {
                    Text("Options")
                        .font(settings.font(size: 13))
                    Spacer()
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .buttonStyle(MenuRowButtonStyle())

            if showOptions {
                OptionsView(settings: settings)
                Divider()
            }

            Divider()

            menuRow(label: "Battery Saver", verticalPadding: 7,
                    action: { onToggle(!state.saverOn) }) {
                Toggle("", isOn: Binding(get: { state.saverOn },
                                         set: { onToggle($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .allowsHitTesting(false)
            }

            Divider()

            menuRow(label: "Quit", action: onQuit)
        }
        .frame(width: 280)
        .background(VisualEffectBlur())
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
        )
    }

    /// Full-width tap-target row used for Battery Saver / Battery Settings /
    /// Quit. `trailing` defaults to nothing, so simple text-only rows don't
    /// need to specify it.
    private func menuRow<Trailing: View>(
        label: String,
        verticalPadding: CGFloat = 9,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(settings.font(size: 13))
                Spacer()
                trailing()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// Ask the app to quit gracefully via NSRunningApplication.terminate(),
    /// which sends a "Quit" Apple Event — works without special perms for most
    /// regular apps. If the request can't be sent (daemon, no longer running,
    /// sandboxed restriction), fall back to surfacing Activity Monitor so the
    /// user can deal with it manually. (Activity Monitor has no public API for
    /// pre-selecting a PID, so we just bring it forward.)
    private func closeOrReveal(_ app: EnergyApp) {
        if let running = NSRunningApplication(processIdentifier: app.pid),
           running.terminate() {
            return
        }
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url,
                                            configuration: NSWorkspace.OpenConfiguration(),
                                            completionHandler: nil)
    }
}

// MARK: - Native vibrancy background

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Shared app state

final class AppState: ObservableObject {
    @Published var saverOn: Bool = false
    @Published var powerSource: String = "—"
    @Published var significantApps: [EnergyApp] = []
}
