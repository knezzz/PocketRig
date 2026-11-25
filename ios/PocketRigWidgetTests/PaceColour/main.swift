// Pace colour cases shared with Dart and Kotlin (test/fixtures/pace_colour.json).
//
//   swiftc ios/PocketRigWidget/UsageRings.swift ios/PocketRigWidgetTests/PaceColour/main.swift -o /tmp/pace-colour
//   /tmp/pace-colour test/fixtures/pace_colour.json
import Foundation

guard CommandLine.arguments.count == 2,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cases = root["cases"] as? [[String: Any]] else {
    fputs("usage: pace-colour <pace_colour.json>\n", stderr)
    exit(2)
}
var failed = 0
for c in cases {
    let ahead = (c["ahead"] as! NSNumber).doubleValue
    let s = PaceColour.segment(ahead)
    let ok = s.from == (c["from"] as! NSNumber).intValue && s.to == (c["to"] as! NSNumber).intValue
        && abs(s.t - (c["t"] as! NSNumber).doubleValue) < 1e-9
    if !ok { failed += 1; print("FAIL ahead \(ahead): got \(s)") }
}
// The ends and the middle are exactly the stops.
let g: UInt32 = 0x34804A, a: UInt32 = 0x616161, r: UInt32 = 0xC2475A
for (ahead, want) in [(-20.0, g), (-5.0, g), (0.0, a), (5.0, r), (20.0, r)] where PaceColour.hex(ahead, green: g, gray: a, red: r) != want {
    failed += 1; print("FAIL colour at \(ahead)")
}
print(failed == 0 ? "pace colour: \(cases.count) cases ok" : "pace colour: \(failed) failed")
exit(failed == 0 ? 0 : 1)
