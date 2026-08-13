// Persistence — atomic state.json read/write for the daemon.
// Ported from Sources/Features/Projects/StatePersistence.swift when
// state ownership moved from the app into the daemon (Phase G Task 5).
//
// Reads/writes ~/Library/Application Support/emux/state.json.
// Writes are debounced (250 ms) and atomic (write-tmp + rename) so a
// crash never produces a partial file. Corruption → rename to
// state.json.corrupt-<timestamp> and start empty.

import Foundation

final class Persistence {
    static let shared = Persistence()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Single serial queue for all disk work.
    private let queue = DispatchQueue(label: "emuxd.persistence", qos: .utility)
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

    /// Load persisted state on daemon startup. Returns the ordered list
    /// of window snapshots (empty if missing/corrupt). Never throws.
    func load() -> [WindowSnapshot] {
        let url = SocketPaths.stateFile
        guard fileManager.fileExists(atPath: url.path) else {
            Log.info("persist", "state.json missing at \(url.path), starting empty")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AppState.self, from: data)
            Log.info("persist", "loaded state.json with \(decoded.windows.count) window(s)")
            return decoded.windows
        } catch {
            Log.error("persist", "state.json corrupt: \(error). Renaming + starting empty.")
            handleCorruption(at: url)
            return []
        }
    }

    /// Snapshot the WorkspaceStore to disk. Debounced 250 ms — bursts
    /// of mutations collapse to a single fsync. Safe to call from any
    /// thread. Store passes in a snapshot builder closure that we
    /// invoke on the persistence queue to avoid deadlocking with the
    /// store's own lock.
    func scheduleSave(snapshotBuilder: @escaping () -> AppState) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let state = snapshotBuilder()
            self?.writeNow(state)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func writeNow(_ state: AppState) {
        let url = SocketPaths.stateFile
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
            Log.debug("persist", "state.json written (\(state.windows.count) windows)")
        } catch {
            Log.error("persist", "state.json write failed: \(error)")
        }
    }

    private func handleCorruption(at url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("state.json.corrupt-\(stamp)")
        try? fileManager.moveItem(at: url, to: backup)
    }
}
