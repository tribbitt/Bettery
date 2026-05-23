import Foundation
import IOKit.pwr_mgt
import AppKit

struct EnergyApp {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
}

// macOS's private PowerLog daemon computes a real per-process "energy impact"
// (CPU + GPU + wakes + I/O + network) and is what Settings/Activity Monitor
// surface as "Apps Using Significant Energy." Third-party apps can't read it.
// The closest public signal: IOPMCopyAssertionsByProcess, which lists every
// process currently holding a power-management assertion (keeping the display
// or system awake). These are the apps Apple flags too — video calls,
// browsers playing media, compilers, downloads, etc.
enum AssertionsMonitor {

    // Only assertions that meaningfully impact energy. We intentionally skip
    // UserIsActive (HID events, fires on any input) and BackgroundTask
    // (transient, not energy-heavy).
    private static let energyImpactingTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypePreventSystemSleep as String,
        kIOPMAssertionTypeNoIdleSleep as String
    ]

    static func appsUsingSignificantEnergy() -> [EnergyApp] {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let dict = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }

        var result: [EnergyApp] = []
        var seen = Set<pid_t>()
        for (pidNum, assertions) in dict {
            let pid = pidNum.int32Value
            if seen.contains(pid) { continue }

            let active = assertions.contains { a in
                guard let type = a["AssertType"] as? String else { return false }
                // AssertLevel > 0 means the assertion is currently holding;
                // some entries linger at level 0 after being released.
                let level = (a["AssertLevel"] as? Int) ?? 255
                return level > 0 && energyImpactingTypes.contains(type)
            }
            guard active else { continue }

            // Skip daemons / agents — they have no UI and would clutter the list.
            // NSRunningApplication only returns regular foreground-capable apps.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }

            let name = app.localizedName ?? app.bundleIdentifier ?? "Process \(pid)"
            result.append(EnergyApp(
                pid: pid,
                name: name,
                icon: app.icon,
                bundleIdentifier: app.bundleIdentifier
            ))
            seen.insert(pid)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
