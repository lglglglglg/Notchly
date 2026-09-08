import AppKit
import Foundation

struct PocketItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class PocketService: ObservableObject {
    @Published private(set) var items: [PocketItem] = []
    @Published private(set) var statusMessage = "拖入文件以临时保存"

    private let settings: AppSettings
    private let fileManager = FileManager.default
    private let directory: URL

    init(settings: AppSettings) {
        self.settings = settings
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appendingPathComponent("Notchly/Pocket", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanExpiredItems()
        reload()
    }

    var usedBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var storageSummary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "(formatter.string(fromByteCount: usedBytes)) / (settings.pocketCapacityMB) MB"
    }

    func importURLs(_ urls: [URL]) {
        cleanExpiredItems()
        var imported = 0
        for source in urls {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }

            let size = allocatedSize(of: source)
            let limit = Int64(settings.pocketCapacityMB) * 1_024 * 1_024
            guard usedBytes + size <= limit else {
                statusMessage = "托盘容量不足，请先清理文件"
                continue
            }
            let destination = uniqueDestination(for: source.lastPathComponent)
            do {
                try fileManager.copyItem(at: source, to: destination)
                imported += 1
                reload()
            } catch {
                statusMessage = "无法保存 (source.lastPathComponent)"
            }
        }
        if imported > 0 {
            statusMessage = "已暂存 (imported) 个文件"
        }
    }

    func clear() {
        for item in items { try? fileManager.removeItem(at: item.url) }
        reload()
        statusMessage = "托盘已清空"
    }

    func reveal(_ item: PocketItem? = nil) {
        if let item {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    func cleanExpiredItems() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(settings.pocketRetentionDays * 86_400))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fileManager.removeItem(at: url) }
        }
    }

    private func reload() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return PocketItem(
                url: url,
                size: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func uniqueDestination(for filename: String) -> URL {
        let original = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let extensionName = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = extensionName.isEmpty ? "(stem) (index)" : "(stem) (index).(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory == true,
           let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            return enumerator.compactMap { $0 as? URL }.reduce(0) { total, child in
                let childValues = try? child.resourceValues(forKeys: keys)
                return total + Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
            }
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
