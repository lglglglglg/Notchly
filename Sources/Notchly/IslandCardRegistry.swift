import CoreGraphics
import Foundation

enum IslandCardID: String, CaseIterable, Codable, Identifiable {
    case power
    case focus
    case calendar
    case reminders
    case pocket

    var id: String { rawValue }
}

enum IslandCardContext: String, CaseIterable, Hashable, Identifiable {
    case musicFooter
    case idleDashboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .musicFooter: "播放时快捷栏"
        case .idleDashboard: "无音乐待机面板"
        }
    }

    var orderingHint: String {
        switch self {
        case .musicFooter: "歌曲展开时显示在底部，四个入口始终等宽。"
        case .idleDashboard: "没有音乐播放时显示，可额外快速查看提醒事项。"
        }
    }
}

struct IslandCardRegistration: Identifiable, Equatable {
    let id: IslandCardID
    let title: String
    let icon: String
    let detail: String
    let contexts: Set<IslandCardContext>
    let defaultEnabled: Bool
}

/// The single catalog for core island modules. Views only decide how a
/// registered card is rendered in a given context; availability, metadata,
/// enablement and default order no longer live in scattered conditionals.
enum IslandCardRegistry {
    static let registrations: [IslandCardRegistration] = [
        IslandCardRegistration(
            id: .power,
            title: "电池",
            icon: "battery.100percent",
            detail: "显示电量和充电状态",
            contexts: [.musicFooter, .idleDashboard],
            defaultEnabled: true
        ),
        IslandCardRegistration(
            id: .focus,
            title: "专注计时",
            icon: "timer",
            detail: "开始、暂停或重置专注时间",
            contexts: [.musicFooter, .idleDashboard],
            defaultEnabled: true
        ),
        IslandCardRegistration(
            id: .calendar,
            title: "下一日程",
            icon: "calendar",
            detail: "查看未来 7 天内的下一项日程",
            contexts: [.musicFooter, .idleDashboard],
            defaultEnabled: true
        ),
        IslandCardRegistration(
            id: .reminders,
            title: "提醒事项",
            icon: "checklist",
            detail: "显示下一条未完成提醒，仅在主动打开时读取",
            contexts: [.idleDashboard],
            defaultEnabled: true
        ),
        IslandCardRegistration(
            id: .pocket,
            title: "文件暂存",
            icon: "tray.full",
            detail: "拖入文件并仅在本机临时保存",
            contexts: [.musicFooter, .idleDashboard],
            defaultEnabled: true
        )
    ]

    static let defaultEnabledIDs = Set(
        registrations.lazy.filter(\.defaultEnabled).map(\.id)
    )

    // Core cards are structural parts of the island rather than optional
    // plug-ins. Keeping them enabled prevents an empty or malformed footer
    // after presets, upgrades, or accidentally clearing every checkbox.
    static let requiredIDs = Set(IslandCardID.allCases)

    private static let defaultContextOrder: [IslandCardContext: [IslandCardID]] = [
        .musicFooter: [.power, .focus, .calendar, .pocket],
        .idleDashboard: [.power, .calendar, .reminders, .focus, .pocket]
    ]

    static func registration(for id: IslandCardID) -> IslandCardRegistration? {
        registrations.first { $0.id == id }
    }

    static func orderedIDs(
        for context: IslandCardContext,
        enabledIDs: Set<IslandCardID>,
        preferredOrder: [IslandCardID]? = nil
    ) -> [IslandCardID] {
        sanitizedOrder(preferredOrder ?? [], for: context)
            .filter(sanitized(enabledIDs).contains)
    }

    static func defaultOrder(for context: IslandCardContext) -> [IslandCardID] {
        sanitizedOrder([], for: context)
    }

    /// Removes unknown/duplicate entries and appends newly registered cards.
    /// This keeps saved orders forward-compatible when modules are added later.
    static func sanitizedOrder(
        _ proposedOrder: some Sequence<IslandCardID>,
        for context: IslandCardContext
    ) -> [IslandCardID] {
        let supported = registrations
            .filter { $0.contexts.contains(context) }
            .map(\.id)
        let supportedSet = Set(supported)
        let fallback = (defaultContextOrder[context] ?? []) + supported
        var seen = Set<IslandCardID>()
        var result = Array(proposedOrder) + fallback
        result = result.filter { supportedSet.contains($0) && seen.insert($0).inserted }

        // File drop remains the final action in the playback shortcut bar, so
        // its position stays predictable even though all four tiles are equal.
        if context == .musicFooter, let pocketIndex = result.firstIndex(of: .pocket) {
            result.append(result.remove(at: pocketIndex))
        }
        return result
    }

    static func moving(
        _ id: IslandCardID,
        by offset: Int,
        in context: IslandCardContext,
        order: [IslandCardID]
    ) -> [IslandCardID] {
        let current = sanitizedOrder(order, for: context)
        guard offset != 0,
              let sourceIndex = current.firstIndex(of: id) else {
            return current
        }
        let targetIndex = sourceIndex + offset
        guard current.indices.contains(targetIndex) else { return current }

        var updated = current
        updated.swapAt(sourceIndex, targetIndex)
        return sanitizedOrder(updated, for: context)
    }

    static func sanitized(_ ids: some Sequence<IslandCardID>) -> Set<IslandCardID> {
        Set(ids)
            .intersection(Set(registrations.map(\.id)))
            .union(requiredIDs)
    }
}
