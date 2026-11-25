import Foundation

// Shared data contract (SPEC.md): key `usage_rings_v1` in the App Group, written by Flutter.
enum UsageStore {
    static let appGroup = "group.dev.pocketrig.pocketRig"
    static let key = "usage_rings_v1"
    static let knownWindows = ["five_hour", "weekly"]

    static func load() -> UsageRings? {
        guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: key) else { return nil }
        return decode(json)
    }

    static func decode(_ json: String) -> UsageRings? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = fractional.date(from: s) ?? plain.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        guard var rings = try? decoder.decode(UsageRings.self, from: Data(json.utf8)) else { return nil }
        // Unknown window values are ignored; rings left with no windows are dropped.
        rings.rings = rings.rings.map { ring in
            var r = ring
            r.windows = ring.windows.filter { knownWindows.contains($0.window) }
            return r
        }.filter { !$0.windows.isEmpty }
        return rings
    }
}

struct UsageRings: Codable {
    var writtenAt: Date?
    var rings: [UsageRing]

    enum CodingKeys: String, CodingKey { case writtenAt, rings }
    init(writtenAt: Date? = nil, rings: [UsageRing]) {
        self.writtenAt = writtenAt
        self.rings = rings
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writtenAt = try c.decodeIfPresent(Date.self, forKey: .writtenAt)
        rings = try c.decodeIfPresent([UsageRing].self, forKey: .rings) ?? []
    }
}

struct UsageRing: Codable, Identifiable {
    var id: String
    var hostLabel: String
    var provider: String
    var windows: [UsageWindow]

    func window(_ name: String) -> UsageWindow? { windows.first { $0.window == name } }
    /// design.md §4: provider capitalised, no logos.
    var providerLabel: String { provider.prefix(1).uppercased() + provider.dropFirst() }
    /// Largest `ahead` over the ring's windows; design.md §8 sorts rows by it.
    func maxAhead(at now: Date) -> Double { windows.map { $0.ahead(at: now) }.max() ?? -.infinity }
}

struct UsageWindow: Codable {
    var window: String
    var windowSeconds: Double
    var usedPercent: Double
    var resetsAt: Date
    var asOf: Date

    var shortLabel: String { window == "five_hour" ? "5h" : "weekly" }

    // Render-time rules from SPEC.md, evaluated against the timeline entry's date.
    func pace(at now: Date) -> Double {
        min(max(1 - resetsAt.timeIntervalSince(now) / windowSeconds, 0), 1)
    }
    func ahead(at now: Date) -> Double { usedPercent / 100 - pace(at: now) }
    /// Percent points ahead of even pace, rounded like the app's strip: used% minus round(pace%).
    func aheadPoints(at now: Date) -> Double { usedPercent - (pace(at: now) * 100).rounded() }
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(asOf) > 3600 }

    /// design.md §5: "in 4h 50m" / "in 42m" / "in 2d 4h" / "now", rounded down.
    func resetPhrase(at now: Date) -> String {
        let minutes = Int(max(resetsAt.timeIntervalSince(now), 0) / 60)
        let hours = minutes / 60
        if minutes < 1 { return "now" }
        if hours < 1 { return "in \(minutes)m" }
        if hours < 24 { return "in \(hours)h " + String(format: "%02dm", minutes % 60) }
        return "in \(hours / 24)d \(hours % 24)h"
    }
    /// design.md §5: "3h ago", "2d ago" beyond 48 h.
    func agoPhrase(at now: Date) -> String {
        let hours = Int(now.timeIntervalSince(asOf) / 3600)
        return hours < 48 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }
    /// Full line under a ring ("Resets in 4h 50m" / "Updated 3h ago") or the short row form ("in 4h 50m" / "3h ago").
    func statusLine(at now: Date, short: Bool) -> String {
        if isStale(at: now) { return short ? agoPhrase(at: now) : "Updated " + agoPhrase(at: now) }
        let p = resetPhrase(at: now)
        return short ? p : "Resets " + p
    }
}

/// The single window furthest ahead of its pace, for the small widget.
struct RingPick {
    let ring: UsageRing
    let window: UsageWindow

    static func furthestAhead(in rings: [UsageRing], at now: Date) -> RingPick? {
        rings.flatMap { ring in ring.windows.map { RingPick(ring: ring, window: $0) } }
            .max { $0.window.ahead(at: now) < $1.window.ahead(at: now) }
    }
}

// Hand-written fixture from the contract JSON in SPEC.md, for Xcode previews and placeholders.
enum UsageFixture {
    static let json = """
    {
      "writtenAt": "2026-11-02T00:20:34.709Z",
      "rings": [
        {
          "id": "host-1/local/claude",
          "hostLabel": "Macmini",
          "provider": "claude",
          "windows": [
            { "window": "five_hour", "windowSeconds": 18000,
              "usedPercent": 4, "resetsAt": "2026-11-02T05:50:00.000Z", "asOf": "2026-11-02T00:20:34.709Z" },
            { "window": "weekly", "windowSeconds": 604800,
              "usedPercent": 57, "resetsAt": "2026-11-04T05:00:00.000Z", "asOf": "2026-11-02T00:19:45.974Z" }
          ]
        },
        {
          "id": "host-2/local/claude",
          "hostLabel": "Studio",
          "provider": "claude",
          "windows": [
            { "window": "five_hour", "windowSeconds": 18000,
              "usedPercent": 88, "resetsAt": "2026-11-02T04:00:00.000Z", "asOf": "2026-11-02T00:20:34.709Z" },
            { "window": "weekly", "windowSeconds": 604800,
              "usedPercent": 64, "resetsAt": "2026-11-04T21:00:00.000Z", "asOf": "2026-11-02T00:19:45.974Z" }
          ]
        },
        {
          "id": "host-1/build-box/codex",
          "hostLabel": "Macmini · build-box",
          "provider": "codex",
          "windows": [
            { "window": "five_hour", "windowSeconds": 18000,
              "usedPercent": 31, "resetsAt": "2026-11-02T02:05:00.000Z", "asOf": "2026-11-02T00:20:34.709Z" }
          ]
        }
      ]
    }
    """
    static let now = ISO8601DateFormatter().date(from: "2026-11-02T01:00:00Z")!
    static var rings: UsageRings { UsageStore.decode(json)! }
    static var onePair: UsageRings { UsageRings(rings: [rings.rings[0]]) }
    static var twoPairs: UsageRings { UsageRings(rings: Array(rings.rings.prefix(2))) }
}

/// Green → gray → red by points ahead of pace: green at -5 or less, gray on pace, red at +5 or more, linear
/// between. Same rule and cases as Dart (test/fixtures/pace_colour.json) and Kotlin.
enum PaceColour {
    static let reach = 5.0
    /// Stops 0 green, 1 gray, 2 red; `t` is how far from `from` to `to`.
    static func segment(_ ahead: Double) -> (from: Int, to: Int, t: Double) {
        if ahead <= -reach { return (0, 0, 0) }
        if ahead >= reach { return (2, 2, 0) }
        return ahead < 0 ? (0, 1, (ahead + reach) / reach) : (1, 2, ahead / reach)
    }
    /// 0xRRGGBB for `ahead`, from the three stops.
    static func hex(_ ahead: Double, green: UInt32, gray: UInt32, red: UInt32) -> UInt32 {
        let stops = [green, gray, red]
        let s = segment(ahead)
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((stops[s.from] >> shift) & 0xFF), b = Double((stops[s.to] >> shift) & 0xFF)
            return UInt32((a + (b - a) * s.t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
