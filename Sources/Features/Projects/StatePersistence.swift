import Foundation
import OSLog

/// Reads/writes `AppState` to `~/Library/Application Support/emux/state.json`.
/// Writes are debounced (250ms) and atomic (write-temp + rename) so a crash
/// never produces a partial file. On corruption, the bad file is preserved as
/// `state.json.corrupt-<timestamp>` and we proceed with `AppState.empty`.
final class StatePersistence {
    static let shared = StatePersistence()

    private let log = Logger(subsystem: "com.ekinertac.emux", category: "persistence")
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Single serial queue for all read/write work. Keeps file ops off the
    /// main thread and avoids tearing if two writes race.
    private let queue = DispatchQueue(label: "com.ekinertac.emux.persistence", qos: .utility)

    /// Debounce timer for `scheduleSave`. Replaced on every call so bursts
    /// of mutations collapse to a single fsync.
    private var pendingWorkItem: DispatchWorkItem?

    private init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Public API

    // In-memory snapshot map. Sourced from disk on load, then mutated
    // by each ProjectsModel via updateWindow / removeWindow. Every
    // mutation schedules a debounced write of the full AppState.
    private var windowsById: [UUID: WindowSnapshot] = [:]
    /// Persisted order of window ids — controls restoration order on
    /// next launch. New windows are appended, closed windows are
    /// removed. Loaded from disk on startup.
    private var order: [UUID] = []
    /// Serialization guard for windowsById/order mutations from
    /// multiple ProjectsModels (each mutates independently via its
    /// own @MainActor context, but the serial queue below owns writes).
    private let lock = NSLock()

    /// Synchronous load. Call once on app launch. Returns the ordered
    /// list of persisted window snapshots. Returns `[]` on missing or
    /// corrupt files — never throws.
    func load() -> [WindowSnapshot] {
        let url = stateFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            log.info("state.json missing, starting empty")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AppState.self, from: data)
            log.info("loaded state.json with \(decoded.windows.count) window(s)")
            lock.lock()
            for w in decoded.windows { windowsById[w.id] = w }
            self.order = decoded.windows.map(\.id)
            lock.unlock()
            return decoded.windows
        } catch {
            log.error("state.json corrupt: \(String(describing: error)). Renaming and starting empty.")
            handleCorruption(at: url)
            return []
        }
    }

    /// Update this window's snapshot. Call from ProjectsModel on any
    /// mutation. Appends to the restore order if this is the first
    /// time we've seen the id. Schedules a debounced disk write.
    func updateWindow(_ snapshot: WindowSnapshot) {
        lock.lock()
        let isNew = windowsById[snapshot.id] == nil
        windowsById[snapshot.id] = snapshot
        if isNew { order.append(snapshot.id) }
        lock.unlock()
        scheduleSave()
    }

    /// Drop a window from persisted state — called when a window is
    /// closed by the user (NOT during app termination, which should
    /// preserve state for next-launch restore).
    func removeWindow(id: UUID) {
        lock.lock()
        windowsById.removeValue(forKey: id)
        order.removeAll { $0 == id }
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Internal

    /// Debounced save of the current in-memory AppState. Bursts within
    /// 250ms collapse to one write.
    private func scheduleSave() {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow()
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func writeNow() {
        lock.lock()
        let orderedWindows = order.compactMap { windowsById[$0] }
        lock.unlock()
        let state = AppState(schemaVersion: AppState.currentSchemaVersion, windows: orderedWindows)

        let url = stateFileURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // rename(2) is atomic on the same volume
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
            log.debug("state.json written (\(state.windows.count) windows)")
        } catch {
            log.error("state.json write failed: \(String(describing: error))")
            // We swallow the error rather than crashing. Next save attempt will retry.
        }
    }

    private func handleCorruption(at url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("state.json.corrupt-\(stamp)")
        try? fileManager.moveItem(at: url, to: backup)
    }

    private func stateFileURL() -> URL {
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("emux", isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
