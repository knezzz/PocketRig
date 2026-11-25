import SwiftUI
import WidgetKit

@main
struct PocketRigWidgetBundle: WidgetBundle {
    var body: some Widget {
        PocketRigWidget()
        if #available(iOS 16.1, *) { PocketRigLiveActivity() }
    }
}

struct PocketRigWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PocketRigWidget", provider: UsageProvider()) { entry in
            UsageEntryView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("Model-account usage per host in the current rate-limit window.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled() // the layouts use their own 14 pt padding
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let data: UsageRings?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: UsageFixture.now, data: UsageFixture.onePair)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : UsageEntry(date: Date(), data: UsageStore.load()))
    }
    // Background fetch first (SPEC.md requirement 7); on total failure the stored blob stays and
    // goes stale. Entries every 15 min for 4 h so pace and greying move even if WidgetKit
    // defers the reload asked for by .after(+15 min). Best effort: the widget never shows an error.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        UsageFetcher.refresh { _ in
            let data = UsageStore.load()
            let start = Date()
            let entries = (0..<16).map { UsageEntry(date: start.addingTimeInterval(Double($0) * 900), data: data) }
            completion(Timeline(entries: entries, policy: .after(start.addingTimeInterval(900))))
        }
    }
}

// MARK: - Colours (light / dark)

enum Palette {
    static let track = Color(light: 0xD9D9D9, dark: 0x3A3A3A)
    static let green = Color(light: 0x1A7F37, dark: 0x3FB950)
    static let accent = Color(light: 0xB4581E, dark: 0xD9915B) // the app's orange: needs you
    static let accentOnBlack = Color(light: 0xD9915B, dark: 0xD9915B) // the island is always black; the light accent is ~4:1 there
    static let working = Color(light: 0x34804A, dark: 0xA1C181) // the app's `added` green: working
    static let workingOnBlack = Color(light: 0xA1C181, dark: 0xA1C181)
    // Pace gradient stops: the app's theme tokens (added / muted / removed), light and dark.
    static func pace(_ ahead: Double) -> Color {
        Color(light: PaceColour.hex(ahead, green: 0x34804A, gray: 0x616161, red: 0xC2475A),
              dark: PaceColour.hex(ahead, green: 0xA1C181, gray: 0xA6A6A6, red: 0xD07277))
    }
    /// The dark stops whatever the system appearance, for the always-black island.
    static func paceOnBlack(_ ahead: Double) -> Color {
        let h = PaceColour.hex(ahead, green: 0xA1C181, gray: 0xA6A6A6, red: 0xD07277)
        return Color(light: h, dark: h)
    }
    static let red = Color(light: 0xCF222E, dark: 0xF85149)
    static let muted = Color(light: 0x616161, dark: 0xA6A6A6)
    static let faint = Color(light: 0x9E9E9E, dark: 0x6E6E6E)
    static let ink = Color(light: 0x1A1A1A, dark: 0xEDEDED)
    static let background = Color(light: 0xFFFFFF, dark: 0x1C1C1E) // tracks and greys were tuned on these

    static func fill(_ w: UsageWindow, at now: Date) -> Color {
        w.isStale(at: now) ? faint : (w.ahead(at: now) > slack ? red : green)
    }
    static func tick(_ w: UsageWindow, at now: Date) -> Color { w.isStale(at: now) ? faint : ink }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

// MARK: - Pace bars

/// Ahead of pace by more than 2 points reads as ahead; within it, on pace (same as the app strip).
let slack = 0.02

/// What's used as a bar, with a tick where even use would be now. `window == nil` draws the track only.
struct BarView: View {
    let window: UsageWindow?
    let now: Date
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: height)
                if let r = window {
                    if r.usedPercent > 0 {
                        Capsule().fill(Palette.fill(r, at: now))
                            .frame(width: max(height, w * min(r.usedPercent / 100, 1)), height: height)
                    }
                    RoundedRectangle(cornerRadius: 1).fill(Palette.tick(r, at: now))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(w * r.pace(at: now) - 1, 0), w - 2))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
    }
}

/// `5h [bar] 62%`; the number is left out when [showNumber] is false.
struct BarRow: View {
    let name: String
    let window: UsageWindow?
    let now: Date
    var height: CGFloat = 8
    var showNumber = true

    var body: some View {
        HStack(spacing: 6) {
            Text(name == "five_hour" ? "5h" : "week").font(.system(size: 11)).foregroundColor(Palette.muted)
                .frame(width: 30, alignment: .leading)
            BarView(window: window, now: now, height: height)
            if showNumber {
                Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .bold)).monospacedDigit()
                    .foregroundColor(window == nil ? Palette.faint : window!.isStale(at: now) ? Palette.ink : Palette.pace(window!.aheadPoints(at: now)))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

extension UsageRing {
    /// The fresh window furthest ahead, or nil when every window is stale.
    func worst(at now: Date) -> UsageWindow? {
        windows.filter { !$0.isStale(at: now) }.max { $0.ahead(at: now) < $1.ahead(at: now) }
    }
    /// "week 11% ahead · in 2d 19h", "on pace", or "Updated 3h ago" when every window is stale.
    func head(at now: Date) -> (text: String, color: Color) {
        guard let w = worst(at: now) else {
            return (windows.first.map { "Updated " + $0.agoPhrase(at: now) } ?? "no data", Palette.faint)
        }
        let ahead = Int((w.ahead(at: now) * 100).rounded())
        if w.ahead(at: now) > slack {
            return ("\(w.window == "five_hour" ? "5h" : "week") \(ahead)% ahead · \(w.resetPhrase(at: now))", Palette.red)
        }
        return ("on pace", Palette.green)
    }
}

// MARK: - Layouts

struct UsageEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let rings = entry.data?.rings, !rings.isEmpty {
                switch family {
                case .systemSmall: SmallView(rings: rings, now: entry.date)
                default: MediumRows(rings: rings, now: entry.date)
                }
            } else {
                EmptyView2()
            }
        }
        .padding(14)
        .widgetBackground()
    }
}

/// Empty state: track bars only plus the prompt.
struct EmptyView2: View {
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                ForEach(UsageStore.knownWindows, id: \.self) { BarRow(name: $0, window: nil, now: Date(), showNumber: false) }
            }
            Text("Open Pocket Rig to connect a host")
                .font(.system(size: 11)).foregroundColor(Palette.muted)
                .multilineTextAlignment(.center).lineLimit(2)
        }
    }
}

/// The account furthest ahead: its worst window as a big number, then both bars.
struct SmallView: View {
    let rings: [UsageRing]
    let now: Date

    var body: some View {
        if let pick = RingPick.furthestAhead(in: rings, at: now) {
            let w = pick.window
            let hot = !w.isStale(at: now) && w.ahead(at: now) > slack
            VStack(alignment: .leading, spacing: 0) {
                RingLabel(ring: pick.ring, weight: .semibold)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text("\(Int(w.usedPercent.rounded()))").font(.system(size: 36, weight: .bold)).tracking(-1)
                        Text("%").font(.system(size: 18, weight: .bold))
                    }
                    .monospacedDigit().foregroundColor(w.isStale(at: now) ? Palette.faint : Palette.pace(w.aheadPoints(at: now)))
                    Text(w.window == "five_hour" ? "5h" : "week")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.muted)
                }
                .padding(.top, 4)
                Text(w.isStale(at: now) ? w.statusLine(at: now, short: false)
                     : (hot ? "\(Int((w.ahead(at: now) * 100).rounded()))% ahead · " : "on pace · ") + w.resetPhrase(at: now))
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.fill(w, at: now)).lineLimit(1)
                    .padding(.top, 4)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    ForEach(UsageStore.knownWindows, id: \.self) {
                        BarRow(name: $0, window: pick.ring.window($0), now: now, height: 6, showNumber: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// `Host · Provider[ · window]` (design.md §4). When it does not fit: drop the host's ` · <daemonHost>`
/// suffix first, then tail-truncate the host; the provider and window are never dropped.
struct RingLabel: View {
    let ring: UsageRing
    var suffix = ""
    let weight: Font.Weight

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                ViewThatFits(in: .horizontal) {
                    whole(ring.hostLabel)
                    whole(shortHost)
                    truncating(shortHost)
                }
            } else {
                truncating(ring.hostLabel) // shortcut: iOS 15 skips the suffix-drop step, upgrade if 15 matters
            }
        }
        .font(.system(size: 11, weight: weight)).foregroundColor(Palette.ink)
    }

    private var shortHost: String { ring.hostLabel.components(separatedBy: " · ")[0] }
    private var tail: String { " · \(ring.providerLabel)\(suffix)" }

    private func whole(_ host: String) -> some View {
        Text(host + tail).lineLimit(1).fixedSize()
    }
    private func truncating(_ host: String) -> some View {
        HStack(spacing: 0) {
            Text(host).lineLimit(1).truncationMode(.tail)
            Text(tail).lineLimit(1).fixedSize().layoutPriority(1)
        }
    }
}

/// Two accounts max, furthest ahead first: label and heading, then 5h and week bars side by side.
struct MediumRows: View {
    let rings: [UsageRing]
    let now: Date

    var body: some View {
        let sorted = rings.sorted { $0.maxAhead(at: now) > $1.maxAhead(at: now) }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sorted.prefix(2)) { ring in
                let head = ring.head(at: now)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        RingLabel(ring: ring, weight: .semibold)
                        Spacer(minLength: 0)
                        Text(head.text).font(.system(size: 11, weight: .semibold)).foregroundColor(head.color)
                            .lineLimit(1).fixedSize()
                    }
                    HStack(spacing: 16) {
                        ForEach(UsageStore.knownWindows, id: \.self) { BarRow(name: $0, window: ring.window($0), now: now) }
                    }
                }
            }
            Spacer(minLength: 0)
            if rings.count > 2 {
                Text("+\(rings.count - 2) more in the app")
                    .font(.system(size: 10)).foregroundColor(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.ink).frame(width: 2, height: 10)
                    Text("where even use would be now").font(.system(size: 10)).foregroundColor(Palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { Palette.background }
        } else {
            background(Palette.background)
        }
    }
}

// MARK: - Previews (fixture data; PreviewProvider so they work on the iOS 15 deployment target)

struct PocketRigWidget_Previews: PreviewProvider {
    static let now = UsageFixture.now
    static var previews: some View {
        Group {
            UsageEntryView(entry: UsageEntry(date: now, data: UsageFixture.onePair))
                .previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("small")
            UsageEntryView(entry: UsageEntry(date: now, data: UsageFixture.rings))
                .previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("small red")
            UsageEntryView(entry: UsageEntry(date: now.addingTimeInterval(3 * 3600), data: UsageFixture.onePair))
                .previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("small stale")
            UsageEntryView(entry: UsageEntry(date: now, data: nil))
                .previewContext(WidgetPreviewContext(family: .systemSmall)).previewDisplayName("small empty")
            UsageEntryView(entry: UsageEntry(date: now, data: UsageFixture.onePair))
                .previewContext(WidgetPreviewContext(family: .systemMedium)).previewDisplayName("medium")
            UsageEntryView(entry: UsageEntry(date: now, data: UsageFixture.twoPairs))
                .previewContext(WidgetPreviewContext(family: .systemMedium)).previewDisplayName("medium two")
            UsageEntryView(entry: UsageEntry(date: now, data: UsageFixture.rings))
                .previewContext(WidgetPreviewContext(family: .systemMedium)).previewDisplayName("medium three")
        }
    }
}
