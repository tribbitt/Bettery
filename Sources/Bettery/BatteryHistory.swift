import Foundation
import Combine

enum BatterySource: String, Codable {
    case live    // 5-sec timer sample, taken while the app is running
    case event   // pmset log event, sparse — could be minutes or hours apart
}

struct BatterySample: Codable, Equatable {
    let timestamp: Date
    let percentage: Double
    let state: BatteryState
    let source: BatterySource

    init(timestamp: Date, percentage: Double, state: BatteryState, source: BatterySource) {
        self.timestamp = timestamp
        self.percentage = percentage
        self.state = state
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, percentage, state, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.percentage = try c.decode(Double.self, forKey: .percentage)
        self.state = try c.decode(BatteryState.self, forKey: .state)

        // Pmset's bucketing always produces timestamps at exact 10-min
        // boundaries (epoch divisible by 600); live samples come from Date()
        // with sub-second precision and essentially never align. We trust this
        // signal OVER any stored `source` value, because a previous app
        // version had a buggy `?? .live` default that re-saved pmset events
        // tagged as live — and once those got persisted, the file would never
        // self-heal under a defer-to-stored-value scheme. Deriving from the
        // timestamp on every load means the data corrects itself on the next
        // save regardless of what was previously written.
        let epoch = self.timestamp.timeIntervalSince1970
        let onBoundary = epoch.truncatingRemainder(dividingBy: 600) < 0.001
        if onBoundary {
            self.source = .event
        } else if let s = try c.decodeIfPresent(BatterySource.self, forKey: .source) {
            self.source = s
        } else {
            self.source = .live
        }
    }
}

final class BatteryHistory: ObservableObject {
    static let shared = BatteryHistory()

    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var sleepIntervals: [SleepInterval] = []

    private let windowDuration: TimeInterval = 24 * 3600
    private let queue = DispatchQueue(label: "bettery.history", qos: .utility)

    // Throttle disk writes: at 5-sec sampling, save every 12 ticks ≈ once per minute.
    // Cheap on SSD and bounds data loss to roughly one minute if the process is killed.
    private var appendsSinceSave = 0
    private let saveEveryNAppends = 12

    private let storeURL: URL? = {
        guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = appSupport.appendingPathComponent("Bettery", isDirectory: true)
        // One-time migration from the old "betterysaver" folder name.
        let oldDir = appSupport.appendingPathComponent("betterysaver", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDir.path) &&
           !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        loadFromDisk()
    }

    /// Synchronous read on init so the graph has data on first render.
    /// At ~17k samples / 24h, decoding is well under 100ms.
    private func loadFromDisk() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BatterySample].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-windowDuration)
        samples = decoded.filter { $0.timestamp >= cutoff }
                        .sorted { $0.timestamp < $1.timestamp }
    }

    /// Backfill from pmset event log. Merges in any events not already covered
    /// by persisted/live samples — these are what give us coverage during sleep
    /// (when our 5-sec timer isn't firing).
    func loadHistorical() {
        queue.async { [weak self] in
            guard let self else { return }
            let hours = Int(self.windowDuration / 3600)
            let parsed = PmsetLogParser.parseLastHours(hours)
            DispatchQueue.main.async {
                let cutoff = Date().addingTimeInterval(-self.windowDuration)
                // Dedup by 1-minute bucket: pmset events at exact 10-min
                // boundaries can land alongside live samples (which sit at
                // arbitrary fractional seconds) without colliding on a
                // whole-second key. Bucketing by minute reliably suppresses
                // those redundant pmset events wherever live coverage exists.
                let liveMinutes = Set(self.samples
                    .filter { $0.source == .live }
                    .map { Int($0.timestamp.timeIntervalSince1970 / 60) })
                let additions = parsed.samples.filter { s in
                    s.timestamp >= cutoff &&
                    !liveMinutes.contains(Int(s.timestamp.timeIntervalSince1970 / 60))
                }
                self.samples = (self.samples + additions)
                    .filter { $0.timestamp >= cutoff }
                    .sorted { $0.timestamp < $1.timestamp }
                self.sleepIntervals = parsed.sleepIntervals.filter { $0.end >= cutoff }
                self.scheduleSave()
            }
        }
    }

    /// Must be called on the main thread (timer callback).
    func append(percentage: Double, state: BatteryState) {
        let sample = BatterySample(timestamp: Date(), percentage: percentage, state: state, source: .live)
        let cutoff = Date().addingTimeInterval(-windowDuration)
        samples.append(sample)
        samples.removeAll { $0.timestamp < cutoff }
        appendsSinceSave += 1
        if appendsSinceSave >= saveEveryNAppends {
            appendsSinceSave = 0
            scheduleSave()
        }
    }

    /// Force a synchronous save — call on app termination so we don't lose
    /// the trailing partial minute of samples between the last throttled write
    /// and shutdown.
    func saveNow() {
        guard let url = storeURL else { return }
        let snapshot = samples
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Bettery: history saveNow failed: \(error)")
        }
    }

    private func scheduleSave() {
        let snapshot = samples
        queue.async { [weak self] in
            guard let self, let url = self.storeURL else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Bettery: history save failed: \(error)")
            }
        }
    }
}
