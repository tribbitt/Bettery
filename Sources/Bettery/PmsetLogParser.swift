import Foundation

struct SleepInterval: Codable, Equatable {
    let start: Date
    let end: Date
}

enum PmsetLogParser {
    /// Parses `pmset -g log` and returns, for the last `hours` hours:
    /// - `samples`: one event-sourced sample per 10-minute slot with activity
    /// - `sleepIntervals`: explicit Sleep → Wake event pairs (DarkWake doesn't end sleep)
    static func parseLastHours(_ hours: Int) -> (samples: [BatterySample], sleepIntervals: [SleepInterval]) {
        guard let output = runPmsetLog() else { return ([], []) }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let events = extractEvents(from: output, cutoff: cutoff)
        return (
            bucketByTenMinutes(events),
            sleepIntervals(from: events)
        )
    }

    // MARK: - Private

    private struct RawEvent {
        let date: Date
        let type: String         // "Sleep", "Wake", "DarkWake", "Assertions", …
        let percentage: Double
        let charging: Bool
    }

    private static func runPmsetLog() -> String? {
        let task = Process()
        task.launchPath = "/bin/bash"
        // Bumped tail to 5000 vs the previous 1000 — Sleep/Wake events are
        // sparser than Assertions, so we need more headroom to capture a full
        // 24h of explicit sleep boundaries. Output is still well under a MB
        // after the grep filter.
        task.arguments = ["-c", "pmset -g log 2>/dev/null | grep -E 'Using (AC|Batt|BATT)' | tail -n 5000"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        // CRITICAL: read BEFORE waitUntilExit. If the pipe buffer fills, the
        // child blocks on write and waitUntilExit never returns → silent hang.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // Group 1: timestamp.  Group 2: event-type word (Sleep, Wake, DarkWake, …).
    // Group 3: AC/Batt.    Group 4: charge percentage.
    private static let linePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(\S+).*?Using (AC|Batt|BATT)\s*[\( ]?Charge:\s*(\d+)"#,
            options: []
        )
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func extractEvents(from output: String, cutoff: Date) -> [RawEvent] {
        guard let pattern = linePattern else { return [] }
        var results: [RawEvent] = []
        output.enumerateLines { line, _ in
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = pattern.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 5,
                  let tsRange   = Range(match.range(at: 1), in: line),
                  let typeRange = Range(match.range(at: 2), in: line),
                  let srcRange  = Range(match.range(at: 3), in: line),
                  let pctRange  = Range(match.range(at: 4), in: line) else { return }
            let tsStr  = String(line[tsRange])
            let type   = String(line[typeRange])
            let src    = String(line[srcRange]).uppercased()
            let pctStr = String(line[pctRange])
            guard let date = formatter.date(from: tsStr),
                  let pct  = Double(pctStr),
                  date >= cutoff else { return }
            results.append(RawEvent(date: date, type: type, percentage: pct, charging: src == "AC"))
        }
        return results
    }

    /// Collapse raw events into one representative sample per 10-minute slot.
    private static func bucketByTenMinutes(_ raw: [RawEvent]) -> [BatterySample] {
        let slotDuration: TimeInterval = 10 * 60
        var buckets: [Int: (total: Double, count: Int, charging: Int)] = [:]
        for e in raw {
            let slot = Int(e.date.timeIntervalSince1970 / slotDuration)
            var b = buckets[slot] ?? (0, 0, 0)
            b.total += e.percentage
            b.count += 1
            b.charging += e.charging ? 1 : 0
            buckets[slot] = b
        }
        return buckets
            .sorted { $0.key < $1.key }
            .map { slot, b in
                let date = Date(timeIntervalSince1970: Double(slot) * slotDuration)
                let avg = b.total / Double(b.count)
                let state: BatteryState = b.charging * 2 > b.count ? .charging : .saverOff
                return BatterySample(timestamp: date, percentage: avg, state: state, source: .event)
            }
    }

    /// Reduces the event stream to explicit Sleep → Wake intervals. DarkWake
    /// fires repeatedly during sleep (TCP keepalive, NTP, Bluetooth, push) and
    /// does NOT end the sleep period — only a real Wake does. Without this
    /// distinction, we'd close every sleep on the first DarkWake and miss
    /// 90%+ of overnight sleep coverage.
    private static func sleepIntervals(from raw: [RawEvent]) -> [SleepInterval] {
        let sorted = raw.sorted { $0.date < $1.date }
        var intervals: [SleepInterval] = []
        var sleepStart: Date? = nil
        for e in sorted {
            switch e.type {
            case "Sleep", "MaintenanceSleep":
                if sleepStart == nil { sleepStart = e.date }
            case "Wake":
                if let start = sleepStart, e.date > start {
                    intervals.append(SleepInterval(start: start, end: e.date))
                }
                sleepStart = nil
            default:
                break    // DarkWake, Assertions, Notification, etc.
            }
        }
        // Unclosed Sleep at the tail = the system was sleeping when the log
        // was captured and woke just now to run us. Close at "now" so the
        // most recent sleep is still visualized.
        if let start = sleepStart {
            intervals.append(SleepInterval(start: start, end: Date()))
        }
        return intervals
    }
}
