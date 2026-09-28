import Foundation
import IOKit.ps

struct PowerSnapshot {
    let level: Int?
    let status: String
    let timeRemaining: String
    let connectionState: PowerConnectionState
}

enum PowerConnectionState: Equatable {
    case battery
    case charging
    case externalPower
}

enum BatteryLevelTone: Equatable {
    case normal
    case warning
    case critical
}

enum BatteryLevelPolicy {
    static func tone(for level: Int?) -> BatteryLevelTone {
        guard let level else { return .normal }
        if level <= 10 { return .critical }
        if level <= 20 { return .warning }
        return .normal
    }
}

enum BatterySymbolPolicy {
    static func symbol(level: Int?, connectionState: PowerConnectionState) -> String {
        switch connectionState {
        case .charging:
            return "battery.100percent.bolt"
        case .externalPower:
            return "powerplug.fill"
        case .battery:
            guard let level else { return "battery.0percent" }
            if level >= 75 { return "battery.100percent" }
            if level >= 35 { return "battery.50percent" }
            return "battery.25percent"
        }
    }
}

@MainActor
final class PowerService {
    func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return PowerSnapshot(
                level: nil,
                status: "未检测到内置电池",
                timeRemaining: "",
                connectionState: .battery
            )
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
        let sourceState = details[kIOPSPowerSourceStateKey] as? String
        let usesExternalPower = sourceState == kIOPSACPowerValue
        let connectionState: PowerConnectionState
        if isCharging {
            connectionState = .charging
        } else if usesExternalPower {
            connectionState = .externalPower
        } else {
            connectionState = .battery
        }
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
        else if usesExternalPower, level == 100 { status = "已接电源 · 已充满" }
        else if usesExternalPower { status = "已接电源" }
        else { status = "使用电池中" }
        return PowerSnapshot(
            level: level,
            status: status,
            timeRemaining: timeRemaining,
            connectionState: connectionState
        )
    }

    private static func timeString(minutes: Int) -> String {
        let hours = minutes / 60
        let minutes = minutes % 60
        return hours > 0 ? "约 \(hours) 小时 \(minutes) 分钟" : "约 \(minutes) 分钟"
    }
}
