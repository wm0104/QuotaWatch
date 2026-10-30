import Foundation

enum WidgetSnapshotStoreError: LocalizedError {
    case appGroupUnavailable
    case invalidSnapshot
    case writeFailed
    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "无法访问小组件 App Group；未使用替代容器。请检查签名、App Group 注册或解锁设备。"
        case .invalidSnapshot:
            return "小组件快照无效，未写入。"
        case .writeFailed:
            return "小组件快照写入失败，原文件已保留。"
        }
    }
}

// The only production directory is the exact App Group container URL. Directory injection exists
// solely for portable Foundation tests; there is no fallback container or UserDefaults mirror.
struct WidgetSnapshotStore {
    static let appGroupID = "group.com.wm0104.quotawatch"
    static let fileName = "widget-snapshot-v1.json"

    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    static func appGroup() throws -> WidgetSnapshotStore {
        #if os(iOS)
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw WidgetSnapshotStoreError.appGroupUnavailable
        }
        return WidgetSnapshotStore(directoryURL: url)
        #else
        throw WidgetSnapshotStoreError.appGroupUnavailable
        #endif
    }

    var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // Missing, unreadable, oversized or corrupt data all mean "no cache" to the widget.
    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty,
              data.count <= WidgetSnapshotLimits.maximumFileBytes else { return nil }
        return WidgetSnapshot.decode(data)
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        let data: Data
        do { data = try snapshot.jsonData() }
        catch { throw WidgetSnapshotStoreError.invalidSnapshot }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            #if os(iOS)
            try data.write(to: fileURL, options: [
                .atomic, .completeFileProtectionUntilFirstUserAuthentication
            ])
            #else
            try data.write(to: fileURL, options: [.atomic])
            #endif
        } catch {
            throw WidgetSnapshotStoreError.writeFailed
        }
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.Code.fileNoSuchFile.rawValue {
            // Already absent is a successful removal; no other file is touched.
        }
    }
}
