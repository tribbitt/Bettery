import AppKit
import SwiftUI
import Combine

/// A panel that, once anchored, keeps its TOP edge fixed across any frame change —
/// so when the hosting controller resizes the panel (e.g., options expanding),
/// the panel grows downward instead of upward into the menu bar.
final class TopAnchoredPanel: NSPanel {
    var topY: CGFloat = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if topY > 0 { rect.origin.y = topY - rect.size.height }
        super.setFrame(rect, display: flag)
    }
    // Borderless + nonactivating panels default to NO for canBecomeKey, which
    // breaks any control that needs to present an auxiliary window (e.g.,
    // ColorPicker → NSColorPanel). Override to YES so focus + key handling work.
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TopAnchoredPanel!
    private var eventMonitor: Any?

    private let settings = Settings.shared
    private let history = BatteryHistory.shared
    private let monitor = SystemMonitor()
    private let battery = BatteryManager()
    private let appState = AppState()

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingChange = false

    // Cached last sample so the icon can be rebuilt off-tick when a Settings
    // color change comes through. Without this, the menu bar wouldn't update
    // until the next 5-sec tick after you pick a new color.
    private var lastBatteryPct: Double = 100
    private var lastBatteryState: BatteryState = .saverOff

    // Lazily decode the PNG once and pre-compute the smiley-only mask used
    // when "Contrasty Smiley" is enabled. trimTransparentEdges + the
    // exterior flood-fill are O(W*H) and shouldn't run on every redraw.
    private lazy var iconAssets: (croppedCG: CGImage, smileyCG: CGImage?, outlineCG: CGImage?, pxToPt: CGFloat)? = {
        guard let url = Bundle.module.url(forResource: "betterywhiteicon", withExtension: "png"),
              let original = NSImage(contentsOf: url),
              let originalCG = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let croppedCG = trimTransparentEdges(originalCG) else { return nil }
        let pxToPt = original.size.width / CGFloat(originalCG.width)
        let smileyCG = extractSmileyImage(croppedCG)
        // outlineCG = croppedCG with smiley pixels punched out via destinationOut,
        // used when "Smiley" is toggled off so the dots don't bleed through at 75%.
        let outlineCG: CGImage? = smileyCG.flatMap { smiley in
            let w = croppedCG.width, h = croppedCG.height
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(croppedCG, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setBlendMode(.destinationOut)
            ctx.draw(smiley, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        return (croppedCG, smileyCG, outlineCG, pxToPt)
    }()

    // Edge-triggered policy state — we only toggle on transitions, not while a
    // condition is sustained. Without this, the user's manual toggles get reverted
    // on the next tick because the conditions are still "true."
    private var prevHighLoad: Bool? = nil
    private var prevBattHealthy: Bool? = nil
    private var prevCharging: Bool? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.requestAuthorization()
        appState.saverOn = battery.isLowPowerModeEnabled()
        setupStatusItem()
        setupPanel()
        history.loadHistorical()
        startLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush the trailing partial minute of live samples that the throttled
        // background save hasn't picked up yet.
        history.saveNow()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Percentage sits to the LEFT of the icon — .imageRight means
            // "image is positioned to the right of the title."
            button.imagePosition = .imageRight
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            // Tight gap between text and icon.
            button.imageHugsTitle = true
            button.action = #selector(togglePanel(_:))
            button.target = self
        }
        refreshIcon()

        // Rebuild the icon whenever any fill color changes — without this the
        // menu bar wouldn't reflect a freshly picked color until the next tick.
        // dropFirst suppresses the initial CurrentValueSubject emission so we
        // don't double-rebuild during setup. objectWillChange would fire BEFORE
        // the @Published assignment lands, so we'd read the stale color — must
        // subscribe to the publishers themselves.
        let colorTriggers = [
            settings.$fillChargingColor,
            settings.$fillStandardColor,
            settings.$fillSaverColor,
            settings.$fillLowBatteryColor
        ].map { $0.dropFirst().map { _ in () }.eraseToAnyPublisher() }
        let toggleTriggers = [
            settings.$contrastySmiley.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$enableFill.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$enableSmiley.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(colorTriggers + toggleTriggers)
            .sink { [weak self] in self?.refreshIcon() }
            .store(in: &cancellables)

        settings.$showPercentage.dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMenuBarTitle(percentage: self.lastBatteryPct)
            }
            .store(in: &cancellables)

        // Reset edge-detection state when autoBoost is re-enabled so the first
        // tick after re-enable doesn't fire a spurious edge against stale prevs.
        settings.$autoBoost.dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.prevHighLoad = nil
                self.prevBattHealthy = nil
                self.prevCharging = nil
            }
            .store(in: &cancellables)
    }

    /// Updates the menu bar label to the current battery percentage. Called from
    /// the 5-sec tick — cheap, just an NSButton title swap.
    private func updateMenuBarTitle(percentage: Double) {
        guard settings.showPercentage else {
            statusItem.button?.title = ""
            return
        }
        let pct = max(0, min(100, Int(percentage.rounded())))
        statusItem.button?.title = "\(pct)%"
    }

    /// Rebuilds and assigns the menu bar icon from the cached last sample.
    private func refreshIcon() {
        statusItem.button?.image = composedIcon(percentage: lastBatteryPct, state: lastBatteryState)
    }

    /// Composes the menu bar icon: a state-colored fill rect (width = battery %)
    /// drawn underneath, with the smiley PNG layered on top. The PNG's
    /// transparent interior lets the fill show through; opaque pixels (outline,
    /// smiley) sit above the fill.
    private func composedIcon(percentage: Double, state: BatteryState) -> NSImage? {
        guard let assets = iconAssets else { return nil }
        let scale: CGFloat = 0.38
        let renderSize = NSSize(
            width:  CGFloat(assets.croppedCG.width)  * assets.pxToPt * scale,
            height: CGFloat(assets.croppedCG.height) * assets.pxToPt * scale
        )
        let fillFraction = max(0, min(1, percentage / 100.0))
        let fillColor = NSColor(fillColorForBattery(percentage: percentage, state: state))

        let img = NSImage(size: renderSize, flipped: false) { rect in
            // Fill sits inside the battery body with a transparent gap on all
            // sides. Insets are fractions of bounds so they scale with render
            // size. Left/right are separate (right is wider to clear the tip).
            let leftInset    = rect.width  * 0.075
            let rightInset   = rect.width  * 0.22
            let vInset       = rect.height * 0.14
            let cornerRadius = rect.height * 0.12

            let bodyRect = NSRect(
                x: rect.minX + leftInset,
                y: rect.minY + vInset,
                width:  rect.width  - leftInset - rightInset,
                height: rect.height - vInset * 2
            )
            // Fill: rounded rect, width = body × fillFraction. Skipped entirely
            // when the user has Enable Fill turned off (icon shows outline only).
            let visibleWidth = bodyRect.width * fillFraction
            if self.settings.enableFill && visibleWidth > 0.5 {
                let fillRect = NSRect(x: bodyRect.minX, y: bodyRect.minY,
                                      width: visibleWidth, height: bodyRect.height)
                let r = min(cornerRadius, visibleWidth / 2)
                fillColor.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()
            }

            // When smiley is enabled: draw full PNG at 75% then repaint smiley at
            // 100% for crispness. When disabled: draw outlineCG (smiley pixels
            // pre-erased via destinationOut) at full opacity so dots don't bleed.
            if self.settings.enableSmiley && assets.smileyCG != nil {
                NSImage(cgImage: assets.croppedCG, size: rect.size)
                    .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.75)
            } else {
                let src = assets.outlineCG ?? assets.croppedCG
                NSImage(cgImage: src, size: rect.size)
                    .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            if self.settings.enableSmiley, let smiley = assets.smileyCG {
                let smileyColor: NSColor = self.settings.contrastySmiley
                    ? self.contrastNSColor(for: self.fillColorForBattery(
                        percentage: percentage, state: state))
                    : .white
                let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
                    NSImage(cgImage: smiley, size: drawRect.size).draw(in: drawRect)
                    smileyColor.set()
                    drawRect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: rect)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Charging always wins (no urgency while plugged in). When discharging
    /// and battery is below the saver-on threshold, the low-battery color
    /// takes precedence over the saver/standard state so the menu bar reads
    /// as "you need to plug in" rather than blending into the usual palette.
    private func fillColorForBattery(percentage: Double, state: BatteryState) -> Color {
        if state == .charging { return settings.fillChargingColor }
        if percentage < settings.saverOnAtBatt { return settings.fillLowBatteryColor }
        switch state {
        case .saverOn:  return settings.fillSaverColor
        case .saverOff: return settings.fillStandardColor
        case .charging: return settings.fillChargingColor   // unreachable
        }
    }

    /// Extracts the smiley-only pixels from the cropped icon.
    ///
    /// 1. Flood-fill exterior transparency from the padded (0,0) corner.
    /// 2. Connected-component-label all opaque pixels (4-connectivity).
    /// 3. Mark each component as "touches exterior" if any of its pixels has
    ///    a 4-neighbor in the flood-filled exterior.
    /// 4. Smiley = pixels in components that DON'T touch the exterior.
    ///
    /// This correctly excludes both the battery outline (touches exterior on
    /// the outside) and the protruding nub (a separate component surrounded
    /// by exterior). It only keeps components fully enclosed by the body —
    /// i.e., the smiley dots floating in the interior transparency.
    private func extractSmileyImage(_ cg: CGImage) -> CGImage? {
        let origW = cg.width, origH = cg.height
        let w = origW + 2, h = origH + 2
        let bpp = 4, bpr = w * bpp
        var pixels = [UInt8](repeating: 0, count: w * h * bpp)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let scan = CGContext(data: &pixels, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        scan.draw(cg, in: CGRect(x: 1, y: 1, width: origW, height: origH))

        // Pass 1: flood-fill exterior. (0,0) is in the padding so guaranteed transparent.
        var exterior = Array(repeating: false, count: w * h)
        var efStack: [(Int, Int)] = [(0, 0)]
        while let (x, y) = efStack.popLast() {
            guard x >= 0, x < w, y >= 0, y < h else { continue }
            let idx = y*w + x
            if exterior[idx] || pixels[y*bpr + x*bpp + 3] > 5 { continue }
            exterior[idx] = true
            efStack.append((x+1, y)); efStack.append((x-1, y))
            efStack.append((x, y+1)); efStack.append((x, y-1))
        }

        // Pass 2: connected-component label opaque pixels (4-connectivity).
        // touchesExterior[i] becomes true if any pixel of component i has
        // an exterior neighbor — i.e., it's part of the outline or the nub.
        var label = Array(repeating: -1, count: w * h)
        var touchesExterior: [Bool] = []
        for y in 0..<h {
            for x in 0..<w {
                guard pixels[y*bpr + x*bpp + 3] > 5, label[y*w + x] == -1 else { continue }
                let id = touchesExterior.count
                touchesExterior.append(false)
                var stack: [(Int, Int)] = [(x, y)]
                while let (cx, cy) = stack.popLast() {
                    guard cx >= 0, cx < w, cy >= 0, cy < h else { continue }
                    let pIdx = cy*w + cx
                    if label[pIdx] != -1 || pixels[cy*bpr + cx*bpp + 3] <= 5 { continue }
                    label[pIdx] = id
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = cx + dx, ny = cy + dy
                        if nx >= 0, nx < w, ny >= 0, ny < h, exterior[ny*w + nx] {
                            touchesExterior[id] = true
                        }
                    }
                    stack.append((cx+1, cy)); stack.append((cx-1, cy))
                    stack.append((cx, cy+1)); stack.append((cx, cy-1))
                }
            }
        }

        // Pass 3: emit only pixels whose component is enclosed by the body.
        let outBpr = origW * bpp
        var smileyBuf = [UInt8](repeating: 0, count: origW * origH * bpp)
        var foundAny = false
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let l = label[y*w + x]
                guard l != -1, !touchesExterior[l] else { continue }
                let srcIdx = y*bpr + x*bpp
                let dstIdx = (y - 1)*outBpr + (x - 1)*bpp
                smileyBuf[dstIdx + 0] = 255
                smileyBuf[dstIdx + 1] = 255
                smileyBuf[dstIdx + 2] = 255
                smileyBuf[dstIdx + 3] = pixels[srcIdx + 3]
                foundAny = true
            }
        }
        guard foundAny,
              let outCtx = CGContext(data: &smileyBuf, width: origW, height: origH,
                                     bitsPerComponent: 8, bytesPerRow: outBpr, space: cs,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return outCtx.makeImage()
    }

    /// Picks pure black or pure white based on perceived luminance of the fill
    /// color (Rec. 709 weights). Threshold 0.5 = above is "light" → black smiley.
    private func contrastNSColor(for fill: Color) -> NSColor {
        let ns = NSColor(fill).usingColorSpace(.sRGB) ?? .white
        let lum = 0.2126*ns.redComponent + 0.7152*ns.greenComponent + 0.0722*ns.blueComponent
        return lum > 0.5 ? .black : .white
    }

    /// Returns a CGImage cropped to the bounding box of non-transparent pixels.
    private func trimTransparentEdges(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        let bpp = 4, bpr = bpp * w
        var pixels = [UInt8](repeating: 0, count: w * h * bpp)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let alpha = pixels[(y * bpr) + (x * bpp) + 3]
                if alpha > 5 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return cg }
        return cg.cropping(to: CGRect(x: minX, y: minY,
                                      width:  maxX - minX + 1,
                                      height: maxY - minY + 1))
    }

    // MARK: - Panel

    private func setupPanel() {
        let root = MainMenuView(
            history: history,
            settings: settings,
            state: appState,
            onQuit: { NSApp.terminate(nil) },
            onToggle: { [weak self] on in self?.manualToggle(on) },
            onInstallSudoers: { [weak self] in self?.battery.installSudoersRule() ?? false }
        )
        // NSHostingController + .preferredContentSize makes the panel
        // automatically resize as SwiftUI's intrinsic content size changes
        // (e.g., when the options section expands or collapses).
        let hc = NSHostingController(rootView: root)
        hc.sizingOptions = [.preferredContentSize]

        // .nonactivatingPanel is required for a borderless NSPanel to behave
        // properly (without it, the panel won't display from a menu-bar click).
        // We compensate for its responder-chain limitation by explicitly
        // calling NSApp.activate(ignoringOtherApps:) in showPanel so
        // NSColorPanel's changeColor: still reaches the SwiftUI ColorPicker.
        panel = TopAnchoredPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hc
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.hasShadow = true
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Anchor the panel's TOP to the bottom of the menu-bar button.
        let buttonRect = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        panel.topY = buttonRect.minY

        // Trigger initial layout so preferredContentSize is meaningful.
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.preferredContentSize ?? CGSize(width: 280, height: 320)
        // Align panel's right edge to button's right edge, then clamp so it
        // doesn't spill off the left or right edge of the screen.
        let screenMaxX = buttonRect.minX > 0
            ? (NSScreen.screens.first(where: { $0.frame.contains(buttonRect.origin) }) ?? NSScreen.main)?.frame.maxX ?? buttonRect.maxX
            : (NSScreen.main?.frame.maxX ?? buttonRect.maxX)
        var panelX = buttonRect.maxX - size.width
        panelX = min(panelX, screenMaxX - size.width)
        panelX = max(panelX, 0)
        // setFrame goes through TopAnchoredPanel.setFrame, which pins the top.
        panel.setFrame(NSRect(x: panelX, y: 0, width: size.width, height: size.height),
                       display: true)
        // Activate the app so first-responder chain is intact — without this
        // NSColorPanel's changeColor: actions don't reach the ColorPicker.
        // .accessory activation policy means we still don't get a Dock icon.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Dismiss when clicking in another app's window. Clicks inside our own
        // app (the panel itself, the color picker popover, NSColorPanel) don't
        // fire global monitors, so they correctly don't dismiss us.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Sampling loop

    private func startLoop() {
        _ = monitor.sampleCPU()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.fire()
    }

    private func tick() {
        let cpu = monitor.sampleCPU()
        let gpu = monitor.sampleGPU()
        let battPct = battery.batteryPercentage() ?? 100
        let charging = battery.isCharging()
        let saverOn = battery.isLowPowerModeEnabled()
        appState.saverOn = saverOn
        appState.powerSource = battery.powerSourceName()
        appState.significantApps = AssertionsMonitor.appsUsingSignificantEnergy()
        updateMenuBarTitle(percentage: battPct)

        let state: BatteryState = charging ? .charging : saverOn ? .saverOn : .saverOff
        lastBatteryPct = battPct
        lastBatteryState = state
        refreshIcon()
        history.append(percentage: battPct, state: state)
        if settings.autoBoost {
            evaluatePolicy(cpu: cpu, gpu: gpu, batt: battPct, charging: charging, saverOn: saverOn)
        }
    }

    private func evaluatePolicy(cpu: Double, gpu: Double, batt: Double, charging: Bool, saverOn: Bool) {
        // Don't stack up multiple concurrent toggle attempts — a pending one is enough.
        guard !isApplyingChange else { return }

        let highLoad = cpu > settings.saverOffAtCPU || gpu > settings.saverOffAtGPU
        let battHealthy = batt > settings.saverOnAtBatt
        defer {
            prevHighLoad = highLoad
            prevBattHealthy = battHealthy
            prevCharging = charging
        }

        // No action on the very first tick — we have nothing to compare against.
        guard let wasHighLoad = prevHighLoad,
              let wasBattHealthy = prevBattHealthy,
              let wasCharging = prevCharging else { return }

        // Edge: just plugged in → apply the user's "saver on while charging" preference.
        if !wasCharging && charging {
            if settings.saverOnWhileCharging && !saverOn { applySaver(true); return }
            if !settings.saverOnWhileCharging && saverOn { applySaver(false); return }
        }
        // Edge: load transitions low → high AND battery is healthy → turn OFF saver.
        if !wasHighLoad && highLoad && battHealthy && saverOn {
            applySaver(false)
            return
        }
        // Edge: load transitions high → low (below the "on" threshold) → turn ON saver.
        let loadLow = cpu <= settings.saverOnAtCPU && gpu <= settings.saverOnAtGPU
        if wasHighLoad && loadLow && battHealthy && !charging && !saverOn {
            applySaver(true)
            return
        }
        // Edge: battery crosses below the threshold → turn ON saver.
        if wasBattHealthy && !battHealthy && !saverOn {
            applySaver(true)
        }
    }

    private func applySaver(_ on: Bool) {
        isApplyingChange = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.battery.setLowPowerMode(on)
            DispatchQueue.main.async {
                self.isApplyingChange = false
                guard ok else { return }
                self.appState.saverOn = on
                // Recompute cached state and repaint everything now, instead of
                // waiting up to 5 sec for the next tick — otherwise toggling shows
                // stale color/title/graph until the timer fires.
                let charging = self.battery.isCharging()
                self.lastBatteryState = charging ? .charging : on ? .saverOn : .saverOff
                self.history.append(percentage: self.lastBatteryPct, state: self.lastBatteryState)
                self.updateMenuBarTitle(percentage: self.lastBatteryPct)
                self.refreshIcon()
                if self.settings.notificationsEnabled {
                    Notifier.shared.notifyToggle(saverOn: on)
                }
            }
        }
    }

    private func manualToggle(_ on: Bool) { applySaver(on) }
}
