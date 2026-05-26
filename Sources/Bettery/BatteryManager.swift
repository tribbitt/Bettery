import Foundation
import IOKit.ps

enum BatteryState: String, Codable {
    case charging
    case saverOn
    case saverOff
}

final class BatteryManager {
    /// Iterates power-source descriptions and returns the first non-nil extraction.
    /// Centralizes the snapshot/sources/description dance that all IOPS reads share.
    private func firstPowerSource<T>(_ extract: ([String: Any]) -> T?) -> T? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources  = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any],
               let v = extract(desc) { return v }
        }
        return nil
    }

    /// Returns current battery percentage (0-100), or nil if no battery.
    func batteryPercentage() -> Double? {
        firstPowerSource { desc in
            guard let cap = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
            return Double(cap) / Double(max) * 100.0
        }
    }

    /// True if currently plugged in / charging.
    func isCharging() -> Bool {
        firstPowerSource { desc -> Bool? in
            (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue ? true : nil
        } ?? false
    }

    /// Returns the human-readable name of the active power source — one of
    /// "AC Power", "Battery", "Off Line", or "UPS". Falls back to "Unknown"
    /// if IOKit returns nothing (rare on Macs).
    func powerSourceName() -> String {
        firstPowerSource { desc -> String? in
            guard let state = desc[kIOPSPowerSourceStateKey] as? String else { return nil }
            switch state {
            case kIOPSACPowerValue:      return "AC Power"
            case kIOPSBatteryPowerValue: return "Battery"
            case kIOPSOffLineValue:      return "Offline"
            default:                     return state
            }
        } ?? "Unknown"
    }

    /// Returns whether low power mode is enabled for the current power source.
    /// Direct property read — no subprocess. The previous implementation forked
    /// `pmset -g` and parsed its output every 5-sec tick, which alone burned
    /// ~1.7% of CPU sustained (~50ms of fork+exec+pipe per tick).
    func isLowPowerModeEnabled() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static let sudoersFilePath = "/etc/sudoers.d/bettery-pmset"

    /// True iff the passwordless-sudo rule for pmset has been installed.
    static func sudoersInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFilePath)
    }

    /// One-time setup: writes a sudoers fragment letting the current user run
    /// `/usr/bin/pmset` without a password. Prompts for admin credentials once
    /// via osascript; afterwards every toggle is silent.
    @discardableResult
    func installSudoersRule() -> Bool {
        let username = NSUserName()
        // Validate username — only proceed if it's a sane shell-safe identifier.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard !username.isEmpty,
              username.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return false }

        let line = "\(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset\n"

        // Write the rule to a temp file ourselves — /tmp is world-writable, no privileges
        // needed. This keeps the AppleScript shell command quote-free so it isn't mangled
        // by AppleScript's string interpolation (previous version had double quotes inside
        // the shell command, which terminated the outer AppleScript string and silently
        // produced malformed AppleScript that did nothing).
        let tmpPath = "/tmp/bettery-sudoers-rule"
        do {
            try line.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Bettery: writing temp sudoers file failed: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // visudo validates the rule before we copy it to the real sudoers.d directory,
        // so a malformed rule can never break sudo.
        let shell = "/usr/sbin/visudo -cf \(tmpPath) >/dev/null && /usr/bin/install -m 0440 -o root -g wheel \(tmpPath) \(Self.sudoersFilePath)"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        var err: NSDictionary?
        guard let s = NSAppleScript(source: script) else { return false }
        s.executeAndReturnError(&err)
        if let err = err {
            NSLog("Bettery: installSudoersRule failed: \(err)")
            return false
        }
        return Self.sudoersInstalled()
    }

    /// Toggle macOS low power mode.
    ///
    /// Tries `sudo -n pmset …` first, which succeeds silently once the user
    /// has clicked "Allow without password" once (or configured sudoers
    /// manually). If that fails, falls back to osascript, which prompts for
    /// the admin password every time.
    @discardableResult
    func setLowPowerMode(_ enabled: Bool) -> Bool {
        let value = enabled ? "1" : "0"
        if trySudoPmset(value: value) { return true }
        return tryOsascriptPmset(value: value)
    }

    private func trySudoPmset(value: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments  = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", value]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func tryOsascriptPmset(value: String) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(value)\" with administrator privileges"
        var error: NSDictionary?
        if let scriptObj = NSAppleScript(source: script) {
            scriptObj.executeAndReturnError(&error)
            if let error = error {
                NSLog("Bettery: pmset failed: \(error)")
                return false
            }
            return true
        }
        return false
    }

    private func runPmset(args: [String]) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        // Read BEFORE waitUntilExit — pipe fills up and child blocks if you wait first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
