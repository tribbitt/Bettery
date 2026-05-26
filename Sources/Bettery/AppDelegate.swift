import AppKit
import SwiftUI
import Combine

private extension Publisher where Failure == Never {
    /// Drops the initial @Published emission and erases the element type so
    /// many publishers with different values can MergeMany together to drive
    /// a single side-effect sink.
    func voidChanges() -> AnyPublisher<Void, Never> {
        dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
}

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
    // NSPanel defaults canBecomeMain to NO. The modern SwiftUI ColorPicker
    // presents its inline popover via NSColorWell, which refuses to show
    // when the host window can't become main — so the swatch click appears
    // to do nothing. Returning YES restores the popup.
    override var canBecomeMain: Bool { true }
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
    private var wakeObserver: NSObjectProtocol?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var isApplyingChange = false
    // True while display is asleep — party timer is paused regardless of toggle
    // state because cycling colors no one can see is pure waste.
    private var screenAsleep = false

    // Cached last sample so the icon can be rebuilt off-tick when a Settings
    // color change comes through. Without this, the menu bar wouldn't update
    // until the next 5-sec tick after you pick a new color.
    private var lastBatteryPct: Double = 100
    private var lastBatteryState: BatteryState = .saverOff

    /// One decoded PNG with its smiley-pixels mask pre-extracted and a
    /// matching outline (smiley pixels punched out). pxToPt is the per-asset
    /// point-per-pixel scale so renderSize stays consistent across assets.
    private struct IconAsset {
        let croppedCG: CGImage
        let smileyCG: CGImage?
        let outlineCG: CGImage?
        let pxToPt: CGFloat
    }

    // Lazily decode each PNG once and pre-compute the smiley-only mask used
    // when "Dark Smiley" is enabled. trimTransparentEdges + the exterior
    // flood-fill are O(W*H) and shouldn't run on every redraw.
    private lazy var smileyAsset: IconAsset? = loadIconAsset(named: "betterywhiteicon")
    private lazy var frownAsset: IconAsset? = loadIconAsset(named: "betterywhitefrownicon")

    private func loadIconAsset(named name: String) -> IconAsset? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
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
        return IconAsset(croppedCG: croppedCG, smileyCG: smileyCG, outlineCG: outlineCG, pxToPt: pxToPt)
    }

    // Party mode rainbow cycle. We hand the rasterized frames to a
    // CAKeyframeAnimation on a CALayer sublayer of the menu-bar button —
    // Core Animation runs the animation on the render server, so our process
    // does ~zero per-frame work after setup (vs. a Timer-driven button.image
    // setter, which forces an NSStatusItem layout+repaint every frame).
    // partyFrame is no longer per-tick state, but cache building still iterates
    // it 0..<partyFrames to produce one frame per hue step.
    private var partyFrame: Int = 0
    private var partyIconLayer: CALayer?
    private var partyAnimationKey: PartyCacheKey?

    /// Cache of pre-rasterized icon frames while in party. Per-frame cost
    /// drops to one array lookup + button.image assignment; full composedIcon
    /// only runs at cache (re)build. The closure-based NSImage from
    /// composedIcon is rasterized to a CGImage immediately so it doesn't
    /// re-execute against possibly-mutated settings at display time.
    private struct PartyCacheKey: Equatable {
        let pct: Int                // rounded — sub-int fill-width is invisible
        let enableFill: Bool
        let enableSmiley: Bool
        let contrastySmiley: Bool
        // True when composedIcon would pick the frown asset for the current
        // slot. Crossing the low-battery boundary doesn't always change pct
        // (e.g., plugging in at exactly the threshold), so without this flag
        // the cached frames could keep rendering the wrong icon body.
        let useFrown: Bool
    }
    private var partyCache: (key: PartyCacheKey, images: [NSImage])?

    // Edge-triggered policy state — we only toggle on transitions, not while a
    // condition is sustained. Without this, the user's manual toggles get reverted
    // on the next tick because the conditions are still "true."
    private var prevHighLoad: Bool? = nil
    private var prevBattHealthy: Bool? = nil
    private var prevCharging: Bool? = nil

    // Tracks the last computed fill slot so we can fire the warning blink
    // only on the transition INTO low-battery (not every tick while there).
    private var prevFillSlot: FillSlot?

    // Warning-blink state. blinkTimer drives the phase advance; while it's
    // non-nil, refreshIcon and syncPartyTimer short-circuit so the 5-sec
    // sampling tick can't stomp on a blink frame. 6 phases × 500ms = 3 sec;
    // even phases = full-fill warning frame, odd = empty (outline only).
    private var blinkTimer: Timer?
    private var blinkPhase: Int = 0
    private static let blinkPhases: Int = 6
    private static let blinkPhaseInterval: TimeInterval = 0.5

    // Asymmetric debounce for the load-just-dropped → re-engage-LPM transition.
    // Power-boost (LPM off) on high load fires immediately because the user
    // needs performance now; re-engaging LPM waits for `lowLoadReadingsRequired`
    // consecutive low-load ticks so brief dips between sustained bursts (build
    // → edit → build, render → scrub → render) don't keep flipping LPM.
    //
    // 2 ticks × 5 sec/tick = 10 sec of confirmed low load. Note: CPU readings
    // are already 5-sec averages (host_statistics cumulative-tick deltas), so
    // 2 ticks ≈ 15 sec of effective averaging on CPU. GPU is instantaneous
    // (IOAccelerator snapshot), so 2 ticks = exactly 2 snapshots spaced 5 sec
    // apart — less smoothing on the GPU side.
    private var lowLoadStreak: Int = 0
    private static let lowLoadReadingsRequired: Int = 2

    // Fluctuation detector: timestamps of auto-induced saver toggles within
    // the trailing fluctuationWindow. When the count crosses the threshold we
    // notify the user the policy is flapping — once per wake cycle, reset on
    // NSWorkspace.didWakeNotification so they get a fresh warning if it
    // recurs after waking from sleep.
    private var autoToggleTimes: [Date] = []
    private var hasNotifiedFluctuation: Bool = false
    private static let fluctuationWindow: TimeInterval = 300  // 5 min
    private static let fluctuationThreshold: Int = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.requestAuthorization()

        // Prime lastBatteryPct/State from the live system BEFORE setupStatusItem
        // calls refreshIcon — otherwise the first paint uses the property
        // defaults (pct=100, state=.saverOff) and flashes a 100% standard
        // smiley for a few ms before the first tick swaps in the real reading.
        let pct = battery.batteryPercentage() ?? 100
        let charging = battery.isCharging()
        let saverOn = battery.isLowPowerModeEnabled()
        lastBatteryPct = pct
        lastBatteryState = charging ? .charging : saverOn ? .saverOn : .saverOff
        appState.saverOn = saverOn

        setupStatusItem()
        setupPanel()
        setupColorPanelAccessory()
        history.loadHistorical()
        observeWake()
        startLoop()
        refreshNotificationAuthStatus()
        // Settling reconcile 30 sec in: gives IOKit power-source readings and
        // the first CPU/GPU samples time to stabilize before we apply policy.
        // Catches cases where launch happened mid-transition (e.g. just woke
        // from sleep, charger state still flapping).
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.reconcileBehavior()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let nc = NSWorkspace.shared.notificationCenter
        [wakeObserver, screenSleepObserver, screenWakeObserver]
            .compactMap { $0 }
            .forEach { nc.removeObserver($0) }
        // Flush the trailing partial minute of live samples that the throttled
        // background save hasn't picked up yet.
        history.saveNow()
    }

    /// Re-parse pmset's log after every wake so just-ended sleep intervals
    /// land in the graph immediately. Without this, sleeps shorter than the
    /// 30-min live-gap heuristic in combinedSleepIntervals render as a normal
    /// segment until the app is restarted. The 2.5-sec delay gives powerd
    /// time to flush the Wake event into the log before we re-parse it.
    private func observeWake() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // New wake cycle: re-arm the fluctuation notification so the user
            // gets warned again if flapping resumes after sleep.
            self?.hasNotifiedFluctuation = false
            // Refresh battery state immediately rather than waiting up to 5
            // sec for the sampling timer's next firing — otherwise the icon
            // can show a stale frown/smiley right after wake if the battery
            // state changed during sleep.
            self?.tick()
            // User may have changed notification permission via System
            // Settings during sleep — re-query so the banner state is fresh.
            self?.refreshNotificationAuthStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self?.history.loadHistorical()
            }
        }
        // Pause party animation while the display is asleep — invisible work.
        // Timer only runs when a state's party flag is on anyway, and the
        // wake handler re-checks before restarting.
        screenSleepObserver = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenAsleep = true
            self.stopPartyAnimation()
        }
        screenWakeObserver = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screenAsleep = false
            self.syncPartyTimer()
        }
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
            // Sublayer hosts the party-mode CAKeyframeAnimation. Sits on top of
            // the button's title-area rendering; we align its frame to the
            // cell's imageRect so it overlays exactly where button.image
            // would be drawn. Hidden until party state is active.
            button.wantsLayer = true
            if let buttonLayer = button.layer {
                let layer = CALayer()
                // Disable implicit animations on every property we mutate —
                // otherwise frame updates cross-fade and contents swaps blur.
                layer.actions = [
                    "contents": NSNull(),
                    "hidden": NSNull(),
                    "bounds": NSNull(),
                    "position": NSNull(),
                ]
                layer.contentsGravity = .resizeAspect
                layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                layer.isHidden = true
                buttonLayer.addSublayer(layer)
                partyIconLayer = layer
            }
        }
        refreshIcon()

        // Rebuild the icon when any appearance input changes. Subscribing to
        // the @Published publisher directly (not objectWillChange) is required
        // because objectWillChange fires *before* the new value lands.
        Publishers.MergeMany([
            settings.$fillChargingColor.voidChanges(),
            settings.$fillStandardColor.voidChanges(),
            settings.$fillSaverColor.voidChanges(),
            settings.$fillLowBatteryColor.voidChanges(),
            settings.$contrastySmiley.voidChanges(),
            settings.$enableFill.voidChanges(),
            settings.$enableSmiley.voidChanges(),
        ])
        .sink { [weak self] in self?.refreshIcon() }
        .store(in: &cancellables)

        settings.$showPercentage.dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateMenuBarTitle(percentage: self.lastBatteryPct)
            }
            .store(in: &cancellables)

        // Reset edge-detection state when autoBoost re-enables so the first
        // post-enable tick doesn't fire a spurious edge against stale prevs.
        // Streak also resets so any pre-disable partial debounce doesn't carry over.
        settings.$autoBoost.dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.prevHighLoad = nil
                self?.prevBattHealthy = nil
                self?.prevCharging = nil
                self?.lowLoadStreak = 0
            }
            .store(in: &cancellables)

        // Re-evaluate intended behavior whenever any performance/threshold
        // setting changes. reconcileBehavior() applies the autoBoost policy
        // immediately and resyncs the fill color — e.g. raising saverOnAtBatt
        // above the current % should flip the icon to low-battery red now.
        //
        // Debounced (400 ms) because TextField/slider edits emit one value
        // per intermediate value as the user types or drags. Without this,
        // dragging "Low-Power Off at CPU" from 50→90 would fire up to 40
        // pmset attempts in a fraction of a second; with it, one reconcile
        // 400 ms after the user settles. Discrete toggles (autoBoost,
        // saverOnWhileCharging) just take 400 ms to land — imperceptible.
        Publishers.MergeMany([
            settings.$autoBoost.voidChanges(),
            settings.$saverOnWhileCharging.voidChanges(),
            settings.$saverOnAtCPU.voidChanges(),
            settings.$saverOffAtCPU.voidChanges(),
            settings.$saverOnAtGPU.voidChanges(),
            settings.$saverOffAtGPU.voidChanges(),
            settings.$saverOnAtBatt.voidChanges(),
        ])
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] in self?.reconcileBehavior() }
        .store(in: &cancellables)

        // Re-check macOS notification permission when the user toggles the
        // Bettery notifications setting on — covers the case where they
        // disabled then re-enabled via System Settings, or first-time enable
        // after the OS prompt was declined.
        settings.$notificationsEnabled.dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.refreshNotificationAuthStatus() }
            .store(in: &cancellables)

        // Start/stop the rainbow ticker on any per-state Party flag change.
        // syncPartyTimer also picks the right action based on the *current*
        // state, so flipping a flag for an inactive state correctly does
        // nothing visible until that state becomes active.
        Publishers.MergeMany([
            settings.$fillChargingParty.voidChanges(),
            settings.$fillStandardParty.voidChanges(),
            settings.$fillSaverParty.voidChanges(),
            settings.$fillLowBatteryParty.voidChanges(),
        ])
        .sink { [weak self] in self?.syncPartyTimer() }
        .store(in: &cancellables)
        syncPartyTimer()
    }

    /// Wires the NSColorPanel accessory view to the *currently-open* fill
    /// picker's Party flag. SwiftUI ColorPicker forwards to the system
    /// NSColorPanel singleton, whose swatch UI isn't customizable; the panel's
    /// accessoryView slot is the closest macOS allows to "inside the color
    /// picker." Each fill picker row sets appState.activeFillSlot via a
    /// simultaneousGesture; this observer rebuilds the hosted accessory view
    /// to bind the toggle to that slot's flag. Graph picker rows clear the
    /// slot, removing the accessory.
    ///
    /// NSColorPanel close also clears the slot so a stale toggle doesn't
    /// reappear next time the panel opens.
    private func setupColorPanelAccessory() {
        appState.$activeFillSlot
            .removeDuplicates()
            .sink { [weak self] slot in
                guard let self else { return }
                if let slot = slot {
                    let hosting = NSHostingView(rootView: ColorPanelAccessory(settings: self.settings, slot: slot))
                    hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 36)
                    NSColorPanel.shared.accessoryView = hosting
                } else {
                    NSColorPanel.shared.accessoryView = nil
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: NSColorPanel.shared,
            queue: .main
        ) { [weak self] _ in
            self?.appState.activeFillSlot = nil
        }
    }

    /// Updates the menu bar label to the current battery percentage. Called from
    /// the 5-sec tick — cheap, just an NSButton title swap.
    private func updateMenuBarTitle(percentage: Double) {
        let newTitle: String
        if settings.showPercentage {
            let pct = max(0, min(100, Int(percentage.rounded())))
            newTitle = "\(pct)%"
        } else {
            newTitle = ""
        }
        guard statusItem.button?.title != newTitle else { return }
        statusItem.button?.title = newTitle
        // Title-width change shifts the cell's imageRect, so the party
        // sublayer needs to re-align. Async so the button has laid out.
        if partyAnimationKey != nil {
            DispatchQueue.main.async { [weak self] in self?.updatePartyLayerFrame() }
        }
    }

    /// Rebuilds and assigns the menu bar icon from the cached last sample.
    /// In party mode this hands the rasterized frames to Core Animation as
    /// a CAKeyframeAnimation on a sublayer's contents — per-frame compositing
    /// runs in the render server, so our process does essentially no work
    /// while party is active. While a warning blink is in progress, the
    /// blink owns the icon — refreshIcon no-ops so the 5-sec sampling tick
    /// can't clobber a blink frame mid-flash.
    private func refreshIcon() {
        if blinkTimer != nil { return }
        guard let button = statusItem.button else { return }
        if currentStateIsParty && !screenAsleep {
            ensurePartyAnimation()
        } else {
            stopPartyAnimation()
            partyCache = nil
            button.image = composedIcon(percentage: lastBatteryPct, state: lastBatteryState)
        }
    }

    /// Kicks off the 3-second warning-blink sequence. Stops any active party
    /// animation so the button.image blink frames are visible (party resumes
    /// in refreshIcon at the end). Idempotent: a second trigger during an
    /// active blink is ignored.
    private func triggerLowBatteryBlink() {
        guard blinkTimer == nil else { return }
        blinkPhase = 0
        stopPartyAnimation()
        renderBlinkFrame()
        blinkPhase = 1
        let timer = Timer.scheduledTimer(withTimeInterval: Self.blinkPhaseInterval, repeats: true) { [weak self] _ in
            self?.advanceBlink()
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func advanceBlink() {
        if blinkPhase >= Self.blinkPhases {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkPhase = 0
            refreshIcon()       // restores normal icon (and re-engages party if applicable)
            return
        }
        renderBlinkFrame()
        blinkPhase += 1
    }

    /// Even phase = full-fill warning frame; odd = empty (outline only).
    /// Uses the lastBattery* cache so it stays in sync with the most recent
    /// sample without re-reading IOKit.
    private func renderBlinkFrame() {
        guard let button = statusItem.button else { return }
        let frame: BlinkFrame = (blinkPhase % 2 == 0) ? .fullFill : .empty
        button.image = composedIcon(percentage: lastBatteryPct, state: lastBatteryState, blink: frame)
    }

    /// Rasterizes one icon per party frame. Returning the closure-based
    /// NSImage directly would re-run composedIcon's draw block each time the
    /// status item asked for the bitmap — which defeats the cache. The
    /// cgImage(forProposedRect:context:hints:) call forces eager rendering;
    /// the result is wrapped back into NSImage for status-item assignment.
    private func buildPartyImageCache() -> [NSImage] {
        var out: [NSImage] = []
        out.reserveCapacity(Self.partyFrames)
        let saved = partyFrame
        for f in 0..<Self.partyFrames {
            partyFrame = f
            if let img = composedIcon(percentage: lastBatteryPct, state: lastBatteryState),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                out.append(NSImage(cgImage: cg, size: img.size))
            }
        }
        partyFrame = saved
        return out
    }

    /// Composes the menu bar icon: a state-colored fill rect (width = battery %)
    /// drawn underneath, with the smiley PNG layered on top. The PNG's
    /// transparent interior lets the fill show through; opaque pixels (outline,
    /// smiley) sit above the fill.
    /// Optional blink-frame override. .fullFill paints a max-width fill in
    /// the low-battery color regardless of pct/fill settings; .empty paints
    /// no fill at all. Both force the frown asset since blink only fires when
    /// we just entered low-battery state. Used by the warning blink sequence.
    enum BlinkFrame { case fullFill, empty }

    private func composedIcon(percentage: Double, state: BatteryState, blink: BlinkFrame? = nil) -> NSImage? {
        // Frown asset for low-battery state (and during blink); smiley elsewhere.
        // Fall back to smiley if the frown PNG failed to load.
        let useFrown = blink != nil || fillSlot(percentage: percentage, state: state) == .lowBattery
        guard let assets = (useFrown ? frownAsset : smileyAsset) ?? smileyAsset else { return nil }
        let scale: CGFloat = 0.38
        let renderSize = NSSize(
            width:  CGFloat(assets.croppedCG.width)  * assets.pxToPt * scale,
            height: CGFloat(assets.croppedCG.height) * assets.pxToPt * scale
        )
        let drawFill: Bool
        let fillFraction: CGFloat
        let fillColor: NSColor
        switch blink {
        case .fullFill:
            drawFill = true
            fillFraction = 1.0
            fillColor = NSColor(settings.fillLowBatteryColor)
        case .empty:
            drawFill = false
            fillFraction = 0
            fillColor = NSColor(settings.fillLowBatteryColor)  // unused, for smiley contrast
        case nil:
            drawFill = settings.enableFill
            fillFraction = max(0, min(1, percentage / 100.0))
            fillColor = fillNSColorForBattery(percentage: percentage, state: state)
        }

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
            // when the user has Enable Fill turned off (or the blink-empty
            // frame, which also asks for no fill).
            let visibleWidth = bodyRect.width * fillFraction
            if drawFill && visibleWidth > 0.5 {
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
                // Party + Fill off: paint the smiley with the cycling hue so
                // Party Mode has a visible surface even without the fill rect.
                let smileyColor: NSColor
                if self.isPartyState(percentage: percentage, state: state) && !self.settings.enableFill {
                    smileyColor = fillColor
                } else if self.settings.contrastySmiley {
                    smileyColor = self.contrastNSColor(forNS: fillColor)
                } else {
                    smileyColor = .white
                }
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
    /// Each state independently honors its Party flag.
    ///
    /// Which FillSlot drives the icon for the given (pct, state). Single
    /// source of truth — fillNSColorForBattery and isPartyState both go
    /// through here so the color and the timer stay in lock-step.
    private func fillSlot(percentage: Double, state: BatteryState) -> FillSlot {
        if state == .charging { return .charging }
        if percentage < settings.saverOnAtBatt { return .lowBattery }
        return state == .saverOn ? .saver : .standard
    }

    /// Returns NSColor directly (not SwiftUI Color) so the party hot path
    /// avoids the SwiftUI→AppKit bridging conversion 12×/sec.
    private func fillNSColorForBattery(percentage: Double, state: BatteryState) -> NSColor {
        let slot = fillSlot(percentage: percentage, state: state)
        if settings.isParty(for: slot) { return Self.partyColor(frame: partyFrame) }
        return NSColor(settings.fillColor(for: slot).wrappedValue)
    }

    private func isPartyState(percentage: Double, state: BatteryState) -> Bool {
        settings.isParty(for: fillSlot(percentage: percentage, state: state))
    }

    private var currentStateIsParty: Bool {
        isPartyState(percentage: lastBatteryPct, state: lastBatteryState)
    }

    /// Start the rainbow animation iff the *current* fill slot wants party.
    /// State transitions (tick, applySaver, screen wake) and per-state flag
    /// changes all call this — single decision point for animation lifecycle.
    /// Short-circuits while a warning blink is active; the blink end-of-cycle
    /// calls refreshIcon which re-enters party if applicable.
    private func syncPartyTimer() {
        if blinkTimer != nil { return }
        if currentStateIsParty && !screenAsleep {
            ensurePartyAnimation()
        } else {
            stopPartyAnimation()
            // Restore the static state-colored icon if we just left party.
            if !currentStateIsParty, let button = statusItem.button {
                button.image = composedIcon(percentage: lastBatteryPct, state: lastBatteryState)
            }
        }
    }

    // Party-mode color LUT: one NSColor per cycle frame, generated once at
    // first access. Each entry is a 50/50 sRGB blend of:
    //   - OKLCh(L=0.72, max in-gamut C) — perceptually uniform brightness
    //   - HSB(s=1, v=1)                 — maximally vivid but brightness varies
    // The blend lands halfway between "no flash" and "vivid but flashy":
    // perceived Δluma over the cycle ~0.30 (vs ~0.06 for pure OKLCh, ~0.7 for
    // pure HSB) while keeping chroma higher than the pure-OKLCh version.
    //
    // Per-frame runtime cost is one array lookup — no math, no allocation.
    // All the OKLab + gamut-search work happens once when the static is first
    // touched. Memory cost: 60 NSColor references ≈ 1 KB.
    //
    // Why a LUT and not a video file: NSStatusItem renders an NSImage. A video
    // pipeline (AVPlayer + CVDisplayLink + CGImage extraction) would be more
    // moving parts and decode overhead than a pointer swap to a cached color.
    private static let partyL: CGFloat = 0.72
    // 12 fps × 60 frames = 5 sec cycle. Runs as a CAKeyframeAnimation on a
    // CALayer sublayer, so per-frame compositing happens in the render server
    // — our process does no per-frame work. fps and frame count drive only
    // the one-time CGImage rasterization cost (~10-20 ms), not runtime CPU.
    private static let partyFPS: Double = 12
    private static let partyFrames = 60

    private static let partyColors: [NSColor] = {
        var out: [NSColor] = []
        out.reserveCapacity(partyFrames)
        for f in 0..<partyFrames {
            let h = CGFloat(f) / CGFloat(partyFrames)
            // OKLCh leg: binary-search max C in sRGB gamut at partyL.
            var lo: CGFloat = 0, hi: CGFloat = 0.4
            for _ in 0..<22 {
                let mid = (lo + hi) / 2
                if linearRGBInGamut(L: partyL, C: mid, h: h) { lo = mid }
                else { hi = mid }
            }
            let (or, og, ob) = oklchToLinearRGB(L: partyL, C: lo * 0.98, h: h)
            let osR = linearToSRGB(or), osG = linearToSRGB(og), osB = linearToSRGB(ob)
            // HSB leg: s=v=1 simplifies HSV→RGB to lerps between primaries.
            let (hR, hG, hB) = hsbToSRGB(h: h)
            out.append(NSColor(srgbRed: (osR + hR) / 2,
                               green:   (osG + hG) / 2,
                               blue:    (osB + hB) / 2,
                               alpha:   1))
        }
        return out
    }()

    private static func partyColor(frame: Int) -> NSColor {
        partyColors[frame % partyFrames]
    }

    private static func hsbToSRGB(h: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let scaled = h * 6
        let i = Int(scaled.rounded(.down)) % 6
        let f = scaled - floor(scaled)
        switch i {
        case 0: return (1, f, 0)
        case 1: return (1 - f, 1, 0)
        case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1)
        case 4: return (f, 0, 1)
        default: return (1, 0, 1 - f)
        }
    }

    // OKLab → linear sRGB (Björn Ottosson, https://bottosson.github.io/posts/oklab/)
    private static func oklchToLinearRGB(L: CGFloat, C: CGFloat, h: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let hr = h * 2 * .pi
        let a = C * cos(hr)
        let b = C * sin(hr)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        return (
             4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        )
    }

    private static func linearRGBInGamut(L: CGFloat, C: CGFloat, h: CGFloat) -> Bool {
        let (r, g, b) = oklchToLinearRGB(L: L, C: C, h: h)
        return r >= 0 && r <= 1 && g >= 0 && g <= 1 && b >= 0 && b <= 1
    }

    private static func linearToSRGB(_ c: CGFloat) -> CGFloat {
        let v = max(0, min(1, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Idempotent: if the animation is already running with the same cache
    /// key, this is a no-op. Otherwise rebuilds the cache (only if key
    /// changed), rasterizes each NSImage to a CGImage, and installs a
    /// CAKeyframeAnimation on the sublayer's contents key path. Per-frame
    /// compositing is then handled by the render server with no app CPU.
    ///
    /// button.image is set to a transparent placeholder of the correct size
    /// so the variable-length status item still reserves the right width.
    /// The sublayer overlays the (invisible) image area; the title is drawn
    /// to the left and is unaffected.
    private func ensurePartyAnimation() {
        guard let layer = partyIconLayer, let button = statusItem.button else { return }
        let key = PartyCacheKey(
            pct: Int(lastBatteryPct.rounded()),
            enableFill: settings.enableFill,
            enableSmiley: settings.enableSmiley,
            contrastySmiley: settings.contrastySmiley,
            useFrown: fillSlot(percentage: lastBatteryPct, state: lastBatteryState) == .lowBattery
        )
        if partyAnimationKey == key, layer.animation(forKey: "party") != nil { return }

        if partyCache?.key != key {
            partyCache = (key, buildPartyImageCache())
        }
        guard let nsImages = partyCache?.images, !nsImages.isEmpty else { return }
        let cgImages = nsImages.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard cgImages.count == nsImages.count else { return }

        button.image = NSImage(size: nsImages[0].size)
        updatePartyLayerFrame()
        layer.isHidden = false

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = cgImages
        anim.duration = Double(cgImages.count) / Self.partyFPS
        anim.repeatCount = .infinity
        anim.calculationMode = .discrete
        layer.removeAnimation(forKey: "party")
        layer.add(anim, forKey: "party")
        partyAnimationKey = key
    }

    private func stopPartyAnimation() {
        partyIconLayer?.removeAnimation(forKey: "party")
        partyIconLayer?.isHidden = true
        partyAnimationKey = nil
    }

    /// Aligns the party sublayer with the NSButtonCell's image rect so the
    /// animated icon overlays exactly where button.image would have been
    /// drawn. Called when the layer is shown and whenever the button's
    /// width changes (e.g. percentage title flips digits).
    private func updatePartyLayerFrame() {
        guard let button = statusItem.button, let layer = partyIconLayer,
              let cell = button.cell as? NSButtonCell else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = cell.imageRect(forBounds: button.bounds)
        CATransaction.commit()
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
    /// Takes NSColor (not SwiftUI Color) to avoid the bridging conversion on
    /// the party hot path.
    private func contrastNSColor(forNS fill: NSColor) -> NSColor {
        let ns = fill.usingColorSpace(.sRGB) ?? .white
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

        // Re-check notification permission each time the panel opens — the
        // user may have flipped it in System Settings since we last checked.
        // Async, so the banner appears on next layout cycle if state changed.
        refreshNotificationAuthStatus()

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
        // Fall back to the last known good pct (not 100) so a transient IOKit
        // read failure doesn't mask a real low-battery state. On the very
        // first tick lastBatteryPct is already primed from launch.
        let battPct = battery.batteryPercentage() ?? lastBatteryPct
        let charging = battery.isCharging()
        let saverOn = battery.isLowPowerModeEnabled()
        appState.saverOn = saverOn
        appState.powerSource = battery.powerSourceName()
        appState.significantApps = AssertionsMonitor.appsUsingSignificantEnergy()
        updateMenuBarTitle(percentage: battPct)

        let state: BatteryState = charging ? .charging : saverOn ? .saverOn : .saverOff
        lastBatteryPct = battPct
        lastBatteryState = state

        // Fire the warning blink on the transition INTO low-battery. Skipped
        // while display is asleep — and crucially we ALSO skip updating
        // prevFillSlot, so when the display wakes the next tick still sees
        // the pre-sleep slot as "prev" and the now-current low-battery as
        // "new", and the blink fires for the now-visible user.
        // First tick (prevFillSlot == nil) doesn't qualify — launching into
        // already-low state doesn't surprise-blink.
        let newSlot = fillSlot(percentage: battPct, state: state)
        if !screenAsleep {
            if settings.warningBlinkEnabled,
               let prev = prevFillSlot, prev != .lowBattery, newSlot == .lowBattery {
                triggerLowBatteryBlink()
            }
            prevFillSlot = newSlot
        }

        syncPartyTimer()
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
        let loadLow = cpu <= settings.saverOnAtCPU && gpu <= settings.saverOnAtGPU
        let battHealthy = batt > settings.saverOnAtBatt
        // True iff the current power-source preference wants saver on right now.
        let wantsSaver = !charging || settings.saverOnWhileCharging

        // Streak tracking for the debounced LPM re-engagement. Increments only
        // while we're in boost mode (saverOn=false) AND all qualifying
        // conditions hold; any non-qualifying tick resets it. The asymmetry —
        // immediate boost-off, delayed boost-on — matches the user's intent
        // that performance comes back fast and goes away slowly.
        if !saverOn && loadLow && battHealthy && wantsSaver {
            lowLoadStreak += 1
        } else {
            lowLoadStreak = 0
        }

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
        // Edge: just unplugged → turn ON saver (we're on battery now). Skip if
        // load is currently high — don't constrain CPU during an active spike;
        // the debounced streak below will re-enable saver once load clears.
        // Unplug is an explicit user action, so no debounce here.
        if wasCharging && !charging && !saverOn && loadLow {
            lowLoadStreak = 0
            applySaver(true)
            return
        }
        // Edge: load transitions low → high AND battery is healthy → turn OFF saver.
        // Immediate, no debounce — when the user needs performance they need it now.
        if !wasHighLoad && highLoad && battHealthy && saverOn {
            applySaver(false)
            return
        }
        // Debounced: load held low for N consecutive ticks → turn ON saver.
        // Replaces the prior "wasHighLoad && loadLow" edge so brief dips
        // between sustained bursts don't keep flipping LPM.
        if lowLoadStreak >= Self.lowLoadReadingsRequired && !saverOn {
            lowLoadStreak = 0
            applySaver(true)
            return
        }
        // Edge: battery crosses below the threshold → turn ON saver.
        // Immediate — low battery is urgent.
        if wasBattHealthy && !battHealthy && !saverOn {
            applySaver(true)
        }
    }

    /// Tracks who initiated a toggle so we can suppress redundant notifications
    /// (user-initiated → user already knows) and skip fluctuation tracking
    /// for manual flips.
    private enum ToggleSource { case auto, manual }

    private func applySaver(_ on: Bool, source: ToggleSource = .auto) {
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
                self.syncPartyTimer()
                self.refreshIcon()
                // Notify only for auto-policy toggles. Manual flips originate
                // from a user gesture in our own UI, so a notification would
                // just say "you did the thing you just did."
                if self.settings.notificationsEnabled, source == .auto {
                    Notifier.shared.notifyToggle(saverOn: on)
                }
                // Manual toggles don't count toward fluctuation either —
                // we're detecting policy flapping, not user activity.
                if source == .auto {
                    self.recordAutoToggle()
                }
            }
        }
    }

    /// Async-queries the OS notification permission and updates appState so
    /// the inline banner appears/disappears reactively. Called on launch,
    /// on wake (user may have changed it in System Settings during sleep),
    /// when the panel opens (same reason), and when the Bettery notifications
    /// toggle flips to ON (covers first-time enable + re-enable after denial).
    private func refreshNotificationAuthStatus() {
        Notifier.shared.checkAuthorizationStatus { [weak self] status in
            // .notDetermined → never asked; we don't want to scream "blocked"
            // before the user has even seen the prompt. Only an explicit
            // .denied triggers the banner.
            self?.appState.notificationsBlocked = (status == .denied)
        }
    }

    /// Appends a timestamp to the rolling window, prunes stale entries, and
    /// fires the fluctuation notification if (a) the count crosses the
    /// threshold, (b) notifications are enabled, and (c) we haven't already
    /// notified during this wake cycle. The flag is cleared on
    /// NSWorkspace.didWakeNotification.
    private func recordAutoToggle() {
        let now = Date()
        autoToggleTimes.append(now)
        autoToggleTimes.removeAll { now.timeIntervalSince($0) > Self.fluctuationWindow }
        guard autoToggleTimes.count >= Self.fluctuationThreshold else { return }
        guard settings.notificationsEnabled, !hasNotifiedFluctuation else { return }
        hasNotifiedFluctuation = true
        Notifier.shared.notifyFluctuation()
    }

    // User flipped the saver in our menu. Disable autoBoost so the auto policy
    // doesn't immediately undo their choice on the next tick — the user re-enables
    // autoBoost when they want the system to take over again. Also cancels any
    // active warning blink so the user's intended state shows immediately
    // instead of sitting through up to 3 sec of blink frames.
    private func manualToggle(_ on: Bool) {
        cancelBlinkIfActive()
        settings.autoBoost = false
        applySaver(on, source: .manual)
    }

    /// Tears down the blink timer without forcing a redraw — the applySaver
    /// completion that follows will repaint. Idempotent.
    private func cancelBlinkIfActive() {
        guard blinkTimer != nil else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkPhase = 0
    }

    /// Single entrypoint for "re-check what state the app should be in now."
    /// Triggered by performance/threshold setting changes and once 30 sec
    /// after launch (settling pass for initial state).
    ///
    /// - If autoBoost is on: run the policy check and apply if it diverges.
    /// - Always: repaint the icon. Threshold changes (e.g. saverOnAtBatt)
    ///   affect the fill color decision in fillNSColorForBattery even when
    ///   the saver itself doesn't flip.
    private func reconcileBehavior() {
        if settings.autoBoost { reconcileSaverState() }
        refreshIcon()
    }

    /// Compute the saver state that autoBoost would currently want, and apply it
    /// if different from the live state.
    private func reconcileSaverState() {
        guard !isApplyingChange else { return }
        let cpu = monitor.sampleCPU()
        let gpu = monitor.sampleGPU()
        // Same fallback as tick(): last known good rather than 100 so a
        // transient nil from IOKit doesn't mask low-battery.
        let batt = battery.batteryPercentage() ?? lastBatteryPct
        let charging = battery.isCharging()
        let saverOn = battery.isLowPowerModeEnabled()

        let highLoad = cpu > settings.saverOffAtCPU || gpu > settings.saverOffAtGPU
        let battHealthy = batt > settings.saverOnAtBatt
        let wantsSaver = !charging || settings.saverOnWhileCharging

        let desired: Bool
        if !battHealthy {
            desired = true                  // low battery overrides everything
        } else if highLoad && wantsSaver {
            desired = false                 // high load — back off temporarily
        } else {
            desired = wantsSaver
        }

        if desired != saverOn { applySaver(desired) }
    }
}
