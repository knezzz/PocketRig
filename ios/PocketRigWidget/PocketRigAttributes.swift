import ActivityKit
import Foundation

// In both targets (Runner starts the activity, the widget draws it). Shape: host/watcher/PUSH.md §4.
@available(iOS 16.1, *)
struct PocketRigAttributes: ActivityAttributes {
    /// An active rig: `project › rig` with how many of its agents need you and work.
    struct Rig: Codable, Hashable {
        var project: String?
        var rig: String
        var needs: Int
        var working: Int
    }

    /// One provider's usage: percent used in the five-hour and weekly windows, as of `asOf` (epoch seconds), and how many
    /// percent points each is ahead of even pace (negative = behind). The watcher computes the points at push time.
    struct Usage: Codable, Hashable {
        var provider: String
        var h5: Double?
        var wk: Double?
        var h5Ahead: Int?
        var wkAhead: Int?
        var asOf: Double

        enum CodingKeys: String, CodingKey { case provider, h5, wk, h5Ahead, wkAhead, asOf }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decode(String.self, forKey: .provider)
            h5 = try c.decodeIfPresent(Double.self, forKey: .h5)
            wk = try c.decodeIfPresent(Double.self, forKey: .wk)
            // try?: an older watcher sent a Bool here; that just leaves the colour plain.
            h5Ahead = try? c.decode(Int.self, forKey: .h5Ahead)
            wkAhead = try? c.decode(Int.self, forKey: .wkAhead)
            asOf = try c.decode(Double.self, forKey: .asOf)
        }
    }

    struct ContentState: Codable, Hashable {
        var needsCount: Int
        var workingCount: Int
        // Optional so a watcher that doesn't send them yet still decodes; the lines then stay out.
        var rigs: [Rig]?  // active rigs, at most 3; rigCount is the total
        var rigCount: Int?
        var usage: [Usage]?
        var updatedAt: Double
    }

    var host: String
    /// Set when the watcher started the activity: where native posts the activity's push token, and the proof for it.
    var tokenUrl: String?
    var ticket: String?
}
