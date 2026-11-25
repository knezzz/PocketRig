import Foundation

// Background fetch (SPEC.md requirement 7): the timeline provider GETs every host's
// /api/provider/status, reduces exactly as lib/data/usage_rings.dart does, and writes the
// result back under usage_rings_v1 so all three writers produce one interchangeable blob.
// Foundation only: ios/PocketRigWidgetTests/ReducerEquivalence.swift compiles this on macOS.

/// One entry of `usage_hosts_v1`, written by Flutter. Carries no secrets.
struct UsageHost: Decodable {
    let id: String
    let label: String
    let daemonBase: String
}

enum UsageReducer {
    /// Contract `windowSeconds` per window; windows not listed here are skipped.
    static let windowSeconds = ["five_hour": 18000, "weekly": 604800]

    /// Mirrors Dart `_rows(json, 'hostUsage')`: a list, or the list under `hostUsage`, else nothing.
    static func rows(_ body: Any?) -> [[String: Any]] {
        let list = body as? [Any] ?? (body as? [String: Any])?["hostUsage"] as? [Any] ?? []
        return list.compactMap { $0 as? [String: Any] }
    }

    /// Mirrors Dart `usageRingsJson`: freshest reading (max `asOf`, first wins a tie) per
    /// app host / daemon host / provider / window, rings in first-seen order, windows in
    /// first-seen order, rings with no known window dropped, `usedPercent` rounded once.
    static func reduce(_ readings: [(host: UsageHost, rows: [[String: Any]])], writtenAt: Date = Date()) -> [String: Any] {
        typealias Reading = (window: String, usedPercent: Double, resetsAt: Date, asOf: Date)
        var order: [String] = []
        var meta: [String: [String: Any]] = [:]
        var freshest: [String: [Reading]] = [:]
        for (host, rows) in readings {
            for u in rows {
                let daemonHost = u["host"] as? String ?? "local"
                let provider = u["provider"] as? String ?? ""
                let id = "\(host.id)/\(daemonHost)/\(provider)"
                if meta[id] == nil {
                    order.append(id)
                    meta[id] = ["id": id, "provider": provider,
                                "hostLabel": daemonHost == "local" ? host.label : "\(host.label) · \(daemonHost)"]
                    freshest[id] = []
                }
                for w in (u["windows"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                    guard let name = w["window"] as? String, windowSeconds[name] != nil,
                          let used = (w["usedPercent"] as? NSNumber)?.doubleValue,
                          let resetsAt = parseDate(w["resetsAt"]), let asOf = parseDate(w["asOf"]) else { continue }
                    let reading: Reading = (name, used, resetsAt, asOf)
                    if let i = freshest[id]!.firstIndex(where: { $0.window == name }) {
                        if asOf > freshest[id]![i].asOf { freshest[id]![i] = reading }
                    } else {
                        freshest[id]!.append(reading)
                    }
                }
            }
        }
        let rings: [[String: Any]] = order.compactMap { id in
            let windows = freshest[id]!
            if windows.isEmpty { return nil } // a ring with no known window is dropped
            var ring = meta[id]!
            ring["windows"] = windows.map { w -> [String: Any] in
                ["window": w.window, "windowSeconds": windowSeconds[w.window]!,
                 "usedPercent": Int(w.usedPercent.rounded()), // same half-away-from-zero as Dart's round()
                 "resetsAt": iso(w.resetsAt), "asOf": iso(w.asOf)]
            }
            return ring
        }
        return ["writtenAt": iso(writtenAt), "rings": rings]
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
    /// Dart `toUtc().toIso8601String()` shape for the daemon's millisecond timestamps.
    /// shortcut: a non-zero microsecond input would differ (Dart keeps 6 digits), upgrade if the daemon ever emits them.
    static func iso(_ d: Date) -> String { fractional.string(from: d) }
}

enum UsageFetcher {
    static let hostsKey = "usage_hosts_v1"
    private struct HostsBlob: Decodable { let hosts: [UsageHost] }

    static func hosts(in defaults: UserDefaults?) -> [UsageHost] {
        guard let s = defaults?.string(forKey: hostsKey),
              let blob = try? JSONDecoder().decode(HostsBlob.self, from: Data(s.utf8)) else { return [] }
        return blob.hosts
    }

    /// Fetches every host (8 s timeout, a failing host is skipped), reduces, and writes
    /// `usage_rings_v1`. Calls back with the JSON written, or nil when no host answered,
    /// in which case the stored blob is left untouched and the stale rule greys it.
    static func refresh(completion: @escaping (String?) -> Void) {
        let defaults = UserDefaults(suiteName: UsageStore.appGroup)
        // The app's own write reloads the timeline via updateWidget(); fetching again then would
        // only refetch every host for equivalent data, so a blob younger than 2 min is used as is.
        if let recent = UsageStore.load()?.writtenAt, Date().timeIntervalSince(recent) < 120 {
            return completion(nil)
        }
        let hosts = hosts(in: defaults)
        guard !hosts.isEmpty else { return completion(nil) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        let group = DispatchGroup()
        let lock = NSLock()
        var results = [[[String: Any]]?](repeating: nil, count: hosts.count) // nil = host failed

        for (i, host) in hosts.enumerated() {
            let base = host.daemonBase.hasSuffix("/") ? String(host.daemonBase.dropLast()) : host.daemonBase
            guard let url = URL(string: base + "/api/provider/status") else { continue }
            group.enter()
            session.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                guard let data = data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let body = try? JSONSerialization.jsonObject(with: data) else { return }
                lock.lock()
                results[i] = UsageReducer.rows(body)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .global()) {
            session.finishTasksAndInvalidate()
            let readings = zip(hosts, results).compactMap { host, rows in rows.map { (host: host, rows: $0) } }
            guard !readings.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: UsageReducer.reduce(readings)),
                  let json = String(data: data, encoding: .utf8) else { return completion(nil) }
            defaults?.set(json, forKey: UsageStore.key)
            completion(json)
        }
    }
}
