import Foundation
import IOKit
import Darwin

final class SystemMonitor {
    private var prevCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    /// Returns overall CPU usage as a percentage (0-100), averaged across all cores.
    func sampleCPU() -> Double {
        var cpuLoadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuLoadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = cpuLoadInfo.cpu_ticks.0
        let system = cpuLoadInfo.cpu_ticks.1
        let idle = cpuLoadInfo.cpu_ticks.2
        let nice = cpuLoadInfo.cpu_ticks.3

        defer { prevCPUTicks = (user, system, idle, nice) }

        guard let prev = prevCPUTicks else { return 0 }
        let dUser = Double(user &- prev.user)
        let dSystem = Double(system &- prev.system)
        let dIdle = Double(idle &- prev.idle)
        let dNice = Double(nice &- prev.nice)
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return ((dUser + dSystem + dNice) / total) * 100.0
    }

    /// Returns GPU utilization as a percentage (0-100) on Apple Silicon.
    /// Falls back to 0 if unavailable.
    func sampleGPU() -> Double {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var utilization: Double = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else {
                continue
            }
            if let busy = stats["Device Utilization %"] as? Double {
                utilization = max(utilization, busy)
            } else if let busy = stats["Device Utilization %"] as? Int {
                utilization = max(utilization, Double(busy))
            } else if let busy = stats["GPU Activity(%)"] as? Int {
                utilization = max(utilization, Double(busy))
            }
        }
        return utilization
    }
}
