import AppKit
import Foundation

struct PocketItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

private struct PendingPocketImport: Sendable {
    let source: URL
    let destination: URL
    let size: Int64
    let hasSecurityScope: Bool
}

private struct PocketImportResult: Sendable {
    let source: URL
    let destination: URL
    let succeeded: Bool
}

@MainActor
final class PocketService: ObservableObject {
    @Published private(set) var items: [PocketItem] = []
    @Published private(set) var statusMessage = "拖入文件以临时保存"
    @Published private(set) var isImporting = false

    private let settings: AppSettings
    private let fileManager = FileManager.default
    private let directory: URL
    private let importQueue = DispatchQueue(label: "com.notchly.pocket.import", qos: .utility)
    private var pendingImportBytes: Int64 = 0
    private var reservedDestinationNames: Set<String> = []

    init(settings: AppSettings) {
        self.settings = settings
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = support.appendingPathComponent("Notchly/Pocket", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanExpiredItems()
        reload()
    }

    var usedBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var storageSummary: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: usedBytes)) / \(settings.pocketCapacityMB) MB"
    }

    func importURLs(_ urls: [URL]) {
        cleanExpiredItems()
        reload()
        var reservedNames = Set(items.map(\.name))
        reservedNames.formUnion(reservedDestinationNames)
        var imports: [PendingPocketImport] = []
        var rejected = 0

        for source in urls {
            let accessed = source.startAccessingSecurityScopedResource()
            let size = allocatedSize(of: source)
            let plannedBytes = imports.reduce(0) { $0 + $1.size }
            guard PocketStoragePolicy.canStore(
                incomingBytes: size,
                usedBytes: usedBytes + pendingImportBytes + plannedBytes,
                capacityMB: settings.pocketCapacityMB
            ) else {
                if accessed { source.stopAccessingSecurityScopedResource() }
                rejected += 1
                continue
            }
            let filename = PocketStoragePolicy.uniqueFilename(
                for: source.lastPathComponent,
                existingNames: reservedNames
            )
            reservedNames.insert(filename)
            imports.append(PendingPocketImport(
                source: source,
                destination: directory.appendingPathComponent(filename),
                size: size,
                hasSecurityScope: accessed
            ))
        }

        guard !imports.isEmpty else {
            statusMessage = rejected > 0 ? "托盘容量不足，请先清理文件" : "没有可暂存的文件"
            return
        }
        pendingImportBytes += imports.reduce(0) { $0 + $1.size }
        reservedDestinationNames.formUnion(imports.map { $0.destination.lastPathComponent })
        isImporting = true
        statusMessage = "正在暂存 \(imports.count) 个文件…"
        let pendingImports = imports
        let rejectionCount = rejected

        importQueue.async { [weak self] in
            let fileManager = FileManager.default
            let results = pendingImports.map { request -> PocketImportResult in
                defer {
                    if request.hasSecurityScope {
                        request.source.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try fileManager.copyItem(at: request.source, to: request.destination)
                    return PocketImportResult(source: request.source, destination: request.destination, succeeded: true)
                } catch {
                    return PocketImportResult(source: request.source, destination: request.destination, succeeded: false)
                }
            }
            Task { @MainActor [weak self] in
                self?.finishImport(pendingImports, results: results, rejected: rejectionCount)
            }
        }
    }

    private func finishImport(
        _ imports: [PendingPocketImport],
        results: [PocketImportResult],
        rejected: Int
    ) {
        pendingImportBytes = max(0, pendingImportBytes - imports.reduce(0) { $0 + $1.size })
        reservedDestinationNames.subtract(imports.map { $0.destination.lastPathComponent })
        isImporting = !reservedDestinationNames.isEmpty
        reload()
        let imported = results.filter(\.succeeded).count
        let failed = results.count - imported
        switch (imported, failed, rejected) {
        case let (imported, 0, 0):
            statusMessage = "已暂存 \(imported) 个文件"
        case let (imported, _, _) where imported > 0:
            statusMessage = "已暂存 \(imported) 个文件；\(failed + rejected) 个未保存"
        case (_, _, let rejected) where rejected > 0:
            statusMessage = "托盘容量不足，请先清理文件"
        default:
            statusMessage = "无法保存 \(results.first?.source.lastPathComponent ?? "文件")"
        }
    }

    func clear() {
        guard !isImporting else {
            statusMessage = "正在暂存文件，完成后再清空"
            return
        }
        var removed = 0
        var failed = 0
        for item in items {
            do {
                try fileManager.removeItem(at: item.url)
                removed += 1
            } catch {
                failed += 1
            }
        }
        reload()
        switch (removed, failed) {
        case (_, 0): statusMessage = "托盘已清空"
        case (0, _): statusMessage = "无法清空托盘，请检查文件权限"
        default: statusMessage = "已清空 (removed) 个文件；(failed) 个未删除"
        }
    }

    func reveal(_ item: PocketItem? = nil) {
        if let item {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    func cleanExpiredItems() {
        let cutoff = PocketStoragePolicy.expirationCutoff(retentionDays: settings.pocketRetentionDays)
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
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        items = urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return PocketItem(
                url: url,
                // Keep the post-import value consistent with preflight checks:
                // a copied folder consumes the sum of its descendants, not just
                // the allocation for the folder entry itself.
                size: allocatedSize(of: url),
                modifiedAt: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
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

enum PocketStoragePolicy {
    static func canStore(incomingBytes: Int64, usedBytes: Int64, capacityMB: Int) -> Bool {
        guard incomingBytes >= 0, usedBytes >= 0, capacityMB >= 0 else { return false }
        let megabyte: Int64 = 1_024 * 1_024
        // Compare in MB plus a bounded remainder rather than multiplying the
        // configured capacity or adding two potentially large byte counts.
        let wholeMegabytes = usedBytes / megabyte + incomingBytes / megabyte
        let remainder = usedBytes % megabyte + incomingBytes % megabyte
        let requiredMegabytes = wholeMegabytes + remainder / megabyte + (remainder % megabyte == 0 ? 0 : 1)
        return requiredMegabytes <= Int64(capacityMB)
    }

    static func expirationCutoff(retentionDays: Int, now: Date = .now) -> Date {
        now.addingTimeInterval(-TimeInterval(retentionDays * 86_400))
    }

    static func uniqueFilename(for filename: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(filename) else { return filename }
        let url = URL(fileURLWithPath: filename)
        let extensionName = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = extensionName.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(extensionName)"
            if !existingNames.contains(candidate) { return candidate }
            index += 1
        }
    }
}
