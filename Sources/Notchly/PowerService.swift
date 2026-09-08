import Foundation
import IOKit.ps

struct PowerSnapshot {
    let level: Int?
    let status: String
    let timeRemaining: String
}

@MainActor
final class PowerService {
    func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return PowerSnapshot(level: nil, status: "未检测到内置电池", timeRemaining: "")
        }

        let current = details[kIOPSCurrentCapacityKey] as? Int
        let maximum = details[kIOPSMaxCapacityKey] as? Int
        let level: Int?
        if let current, let maximum, maximum > 0 {
            level = Int((Double(current) / Double(maximum) * 100).rounded())
        } else {
            level = nil
        }
        let isCharging = details[kIOPSIsChargingKey] as? Bool ?? false
        let isPresent = details[kIOPSIsPresentKey] as? Bool ?? true
        let minutes = IOPSGetTimeRemainingEstimate()
        let timeRemaining: String
        if minutes > 0, minutes < kIOPSTimeRemainingUnlimited {
            timeRemaining = Self.timeString(minutes: Int(minutes))
        } else {
            timeRemaining = ""
        }
        let status: String
        if !isPresent { status = "未检测到内置电池" }
        else if isCharging { status = "正在充电" }
        else { status = "使用电池中" }
        return PowerSnapshot(level: level, status: status, timeRemaining: timeRemaining)
    }

    private static func timeString(minutes: Int) -> String {
        let hours = minutes / 60
        let minutes = minutes % 60
        return hours > 0 ? "约 \(hours) 小时 \(minutes) 分钟" : "约 \(minutes) 分钟"
    }
}
