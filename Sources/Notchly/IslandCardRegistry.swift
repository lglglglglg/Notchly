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
        case .musicFooter: "音乐展开区"
        case .idleDashboard: "待机面板"
        }
    }

    var orderingHint: String {
        switch self {
        case .musicFooter: "文件暂存需要适应剩余宽度，因此固定在末尾。"
        case .idleDashboard: "决定没有音乐播放时快捷卡片的排列。"
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

/// The single catalog for optional island modules. Views only decide how a
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
            defaultEnabled: false
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
            .filter(enabledIDs.contains)
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

        // The pocket row is the flexible-width item in the music footer. Keeping
        // it last avoids compressed controls and makes the ordering predictable.
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
        Set(ids).intersection(Set(registrations.map(\.id)))
    }
}

enum IslandCardLayoutPolicy {
    static func musicFooterControlsWidth(for ids: [IslandCardID]) -> CGFloat {
        let widths: [CGFloat] = ids.compactMap {
            switch $0 {
            case .power: 72
            case .focus: 132
            case .calendar: 86
            case .reminders: nil
            case .pocket: nil
            }
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1))
    }
}
