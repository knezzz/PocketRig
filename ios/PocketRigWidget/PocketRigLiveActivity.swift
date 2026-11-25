import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct PocketRigLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PocketRigAttributes.self) { ctx in
            LockScreenView(host: ctx.attributes.host, state: ctx.state)
                .padding(14)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LockScreenView(host: ctx.attributes.host, state: ctx.state, limit: 2, island: true)
                }
            } compactLeading: {
                // Nothing at 0; the other count still shows on its side.
                if ctx.state.needsCount > 0 {
                    Text("\(ctx.state.needsCount)").foregroundColor(Palette.accentOnBlack).fontWeight(.bold)
                        .accessibilityLabel("\(ctx.state.needsCount) need you")
                }
            } compactTrailing: {
                if ctx.state.workingCount > 0 {
                    Text("\(ctx.state.workingCount)").foregroundColor(Palette.workingOnBlack).fontWeight(.bold)
                        .accessibilityLabel("\(ctx.state.workingCount) working")
                }
            } minimal: {
                Circle().fill(ctx.state.needsCount > 0 ? Palette.accentOnBlack : Palette.workingOnBlack).frame(width: 10, height: 10)
                    .accessibilityLabel(ctx.state.needsCount > 0 ? "\(ctx.state.needsCount) need you" : "\(ctx.state.workingCount) working")
            }
        }
    }
}

/// Lean card, no links (a tap anywhere opens the app; needs-you agents are reached from the notification):
/// totals, one line per active rig (needs · working), and usage. The island is always black, so it uses white
/// text and the on-black colours whatever the system appearance.
@available(iOS 16.1, *)
struct LockScreenView: View {
    let host: String
    let state: PocketRigAttributes.ContentState
    var limit = 3
    var island = false

    var body: some View {
        let accent = island ? Palette.accentOnBlack : Palette.accent
        let working = island ? Palette.workingOnBlack : Palette.working
        let faint = island ? Color.white.opacity(0.6) : Palette.muted
        let ink = island ? Color.white : Palette.ink
        let rigs = Array((state.rigs ?? []).prefix(limit))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                totals(accent, working, faint)
                Spacer(minLength: 8)
                Text(host).font(.caption).foregroundColor(faint).lineLimit(1)
            }
            ForEach(Array(rigs.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    Text([r.project, r.rig].compactMap { $0 }.joined(separator: " › "))
                        .font(.footnote).foregroundColor(ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    counts(r, accent, working, faint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(r.rig): \(r.needs) need you, \(r.working) working")
            }
            let more = (state.rigCount ?? rigs.count) - rigs.count
            if more > 0 { Text("+\(more) more").font(.caption).foregroundColor(faint) }
            usageLine(faint)
        }
    }

    private func totals(_ accent: Color, _ working: Color, _ faint: Color) -> some View {
        let n = state.needsCount, w = state.workingCount
        return HStack(spacing: 6) {
            if n > 0 { Text("\(n) need you").foregroundColor(accent) }
            if n > 0 && w > 0 { Text("·").foregroundColor(faint) }
            if w > 0 { Text("\(w) working").foregroundColor(working) }
            if n == 0 && w == 0 { Text("idle").foregroundColor(faint) }  // the watcher holds the card 10 min before ending it
        }
        .font(.subheadline.weight(.bold))
        .accessibilityElement(children: .combine)
    }

    private func counts(_ r: PocketRigAttributes.Rig, _ accent: Color, _ working: Color, _ faint: Color) -> some View {
        HStack(spacing: 4) {
            if r.needs > 0 { Text("\(r.needs)").foregroundColor(accent) }
            if r.needs > 0 && r.working > 0 { Text("·").foregroundColor(faint) }
            if r.working > 0 { Text("\(r.working)").foregroundColor(working) }
        }
        .font(.footnote.weight(.semibold)).monospacedDigit()
    }

    /// `Claude 42% · 71%   Codex 8% · 30%`: five-hour then weekly; red from 90 %, dimmed when older than 15 min.
    @ViewBuilder private func usageLine(_ faint: Color) -> some View {
        let usage = Array((state.usage ?? []).prefix(2))
        if !usage.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(usage.enumerated()), id: \.offset) { _, u in
                    let stale = Date().timeIntervalSince1970 - u.asOf > 15 * 60
                    HStack(spacing: 4) {
                        Text(u.provider)
                        percent(u.h5, ahead: u.h5Ahead)
                        Text("·")
                        percent(u.wk, ahead: u.wkAhead)
                    }
                    .opacity(stale ? 0.7 : 1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption).monospacedDigit().foregroundColor(faint).lineLimit(1)
        }
    }

    /// Coloured on the pace gradient (green → amber → red); plain when pace is unknown. On black the dark stops.
    private func percent(_ v: Double?, ahead: Int?) -> Text {
        guard let v else { return Text("–") }
        let t = Text("\(Int(v.rounded()))%")
        guard let ahead else { return t }
        return t.foregroundColor(island ? Palette.paceOnBlack(Double(ahead)) : Palette.pace(Double(ahead)))
    }
}
