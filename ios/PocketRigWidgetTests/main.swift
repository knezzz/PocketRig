// Reducer equivalence check (SPEC.md Decisions: "same input JSON produces the same usage_rings_v1 blob").
// A plain script (main.swift so swiftc accepts top-level code) instead of an XCTest target: it runs on
// macOS with no simulator and no pbxproj churn.
//
//   swiftc ios/PocketRigWidget/UsageRings.swift ios/PocketRigWidget/UsageFetcher.swift \
//          ios/PocketRigWidgetTests/main.swift -o /tmp/reducer-eq
//   /tmp/reducer-eq test/fixtures/usage_rings_input.json test/fixtures/usage_rings_expected.json
//
// input.json:    { "hosts": [ { "id": "<appHostId>", "name" | "label": "Macmini" } ],
//                  "responses": { "<appHostId>": <raw GET /api/provider/status body> } }
// expected.json: the usage_rings_v1 blob Dart produces. writtenAt is ignored on both sides.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: reducer-eq <input.json> <expected.json>\n", stderr)
    exit(2)
}
func load(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("cannot read JSON object from \(path)\n", stderr)
        exit(2)
    }
    return obj
}
func pretty(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

let input = load(args[1])
var expected = load(args[2])
let hosts = (input["hosts"] as? [[String: Any]] ?? []).map {
    UsageHost(id: $0["id"] as! String, label: ($0["label"] ?? $0["name"]) as! String, daemonBase: "")
}
let responses = input["responses"] as? [String: Any] ?? [:]
var actual = UsageReducer.reduce(hosts.map { (host: $0, rows: UsageReducer.rows(responses[$0.id])) })
actual["writtenAt"] = nil
expected["writtenAt"] = nil

if NSDictionary(dictionary: actual).isEqual(to: expected) {
    print("OK: Swift reducer output equals \(args[2]) (writtenAt ignored)")
    exit(0)
}
print("MISMATCH\n--- swift ---\n\(pretty(actual))\n--- expected ---\n\(pretty(expected))")
exit(1)
