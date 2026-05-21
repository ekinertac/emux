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

    /// Synchronous load. Call this once on app launch. Returns `AppState.empty`
    /// if the file is missing or corrupt — never throws to the caller.
    func load() -> AppState {
        let url = stateFileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            log.info("state.json missing, starting empty")
            return .empty
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AppState.self, from: data)
            log.info("loaded state.json with \(decoded.projects.count) projects")
            return decoded
        } catch {
            log.error("state.json corrupt: \(String(describing: error)). Renaming and starting empty.")
            handleCorruption(at: url)
            return .empty
        }
    }

    /// Debounced save. Call after every model mutation. Bursts within 250ms
    /// collapse to one write.
    func scheduleSave(_ state: AppState) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeNow(state)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    // MARK: - Internal

    private func writeNow(_ state: AppState) {
        let url = stateFileURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            // rename(2) is atomic on the same volume
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
            log.debug("state.json written (\(state.projects.count) projects)")
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
