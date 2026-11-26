import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/fleet.dart';
import '../main.dart';
import '../models.dart';
import 'action_rows.dart';
import '../terminal/transport.dart' show SeatTarget;
import 'chat_screen.dart' show ChatScreen;
import 'desktop_shell.dart' show detailNavigator, panelShows;
import 'loose_agent_screen.dart' show looseActionRows;
import 'needs_you_banner.dart' show seatScreenRoutes;
import 'terminal_screen.dart' show TerminalScreen;
import 'host_actions.dart';
import 'project_actions.dart';
import 'rig/rig_actions.dart';
import 'rig/seat_actions.dart';
import 'theme.dart';

/// One line of the palette: what it does, under which heading.
class PaletteCommand {
  const PaletteCommand(this.group, this.label, this.icon, this.run, {this.detail, this.danger = false});
  final String group;
  final String label;
  final String? detail;
  final IconData icon;
  final VoidCallback run;
  final bool danger;
}

/// An action list's rows as palette lines: the same rows the ⋯ sheet shows, so a new action shows up in both.
List<PaletteCommand> commandsFromRows(String group, ActionRows rows) => [
      for (final (icon, label, detail, run) in rows.items)
        if (run != null) PaletteCommand(group, label, icon, run, detail: detail),
      for (final (label, icon, run) in rows.danger) PaletteCommand(group, label, icon, run, danger: true),
    ];

/// Everything ⌘⇧P offers: the actions of what the panel shows (a seat, a rig or a project: the very lists their ⋯
/// opens), each host's list, then where to go. The shell passes how it opens things.
List<PaletteCommand> paletteCommands(
  BuildContext context, {
  required VoidCallback onInbox,
  required VoidCallback onSettings,
  required void Function(Host host, String path) onProject,
  required void Function(Host host, Project project, RigWithSeats rig) onRig,
}) {
  final store = AppScope.read(context);
  final shown = panelShows.value;
  final out = <PaletteCommand>[];
  final hosts = store.hosts;
  // The selection's own list first. Its screens read the active host, so only the active host's objects qualify.
  final active = store.active;
  if (active != null && shown != null) {
    final feed = fleet.feedFor(active);
    Future<void> refresh() => feed.refresh();
    // A kill or remove of the seat on show: its chat or terminal leaves the panel, as the sheet's onGone does.
    // Only a chat or terminal leaves: tiles with the seat enlarged stay.
    void leave() {
      final nav = detailNavigator(context);
      Route<dynamic>? top;
      nav.popUntil((r) {
        top = r;
        return true;
      });
      if (top != null && seatScreenRoutes.contains(top) && nav.canPop()) nav.pop(); // never the panel root
    }
    for (final p in feed.projects) {
      if (shown == 'project:${p.path}') {
        out.addAll(commandsFromRows('Project · ${p.name}', projectActionRows(context, p.path)));
      }
      for (final r in p.rigs) {
        if (shown == 'rig:${r.rig.id}') {
          out.addAll(commandsFromRows(
              'Rig · ${active.rigLabel(r.rig.name)}', rigActionRows(context, r.rig, r.seats, projectName: p.name)));
        }
        for (final s in r.seats) {
          if (shown == 'seat:${s.rigId}/${s.logicalId}') {
            out.addAll(commandsFromRows(
                'Seat · ${s.logicalId}', seatMenuRows(context, r.rig.name, s, onRefresh: refresh, onGone: leave)));
          }
        }
      }
      for (final a in p.loose) {
        final s = a.toSeat();
        if (shown == 'seat:${s.rigId}/${s.logicalId}') {
          final nav = detailNavigator(context);
          out.addAll(commandsFromRows(
              'Agent · ${a.name}',
              looseActionRows(context, a,
                  onChat: () => nav.push(MaterialPageRoute(
                      builder: (_) => ChatScreen(rigName: 'no rig', seat: s, loose: a, rigs: feed.rigs, asChat: true))),
                  onTerminal: () => nav.push(MaterialPageRoute(
                      builder: (_) => TerminalScreen(target: SeatTarget('no rig', s)))),
                  onRenamed: refresh,
                  onKilled: leave)));
        }
      }
    }
  }
  for (final h in hosts) {
    // Named by the host here: the palette lists one Rescan per host, and the host's own sheet has its name as title.
    for (final c in commandsFromRows('Host', hostActionRows(h))) {
      out.add(PaletteCommand(c.group, '${c.label} ${h.name}', c.icon, c.run, detail: c.detail, danger: c.danger));
    }
  }
  out.add(PaletteCommand('Go to', 'Inbox', Icons.inbox_outlined, onInbox));
  out.add(PaletteCommand('Go to', 'Hosts and settings', Icons.settings_outlined, onSettings));
  for (final h in hosts) {
    final feed = fleet.feedFor(h);
    for (final p in feed.projects) {
      out.add(PaletteCommand('Go to', p.name, Icons.folder_outlined, () => onProject(h, p.path),
          detail: hosts.length > 1 ? h.name : null));
      for (final r in p.rigs) {
        if (r.rig.status == 'stopped') continue;
        out.add(PaletteCommand('Go to', h.rigLabel(r.rig.name), Icons.grid_view_outlined, () => onRig(h, p, r),
            detail: '${p.name} · rig'));
      }
    }
  }
  return out;
}

/// Whether [c] matches [query]: every word of it appears in the group, label or detail, in any order.
bool paletteMatches(PaletteCommand c, String query) {
  final hay = '${c.group} ${c.label} ${c.detail ?? ''}'.toLowerCase();
  return query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
}

/// The palette: a filter box over a list; ↑↓ move, ⏎ runs, Esc closes. A command runs after the palette has closed.
Future<void> showCommandPalette(BuildContext context, List<PaletteCommand> commands) async {
  final pick = await showDialog<PaletteCommand>(
    context: context,
    builder: (_) => _Palette(commands),
  );
  if (pick != null && context.mounted) pick.run();
}

class _Palette extends StatefulWidget {
  const _Palette(this.commands);
  final List<PaletteCommand> commands;
  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _query = TextEditingController();
  int _at = 0;

  List<PaletteCommand> get _shown => [for (final c in widget.commands) if (paletteMatches(c, _query.text)) c];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _move(int by) {
    final n = _shown.length;
    if (n > 0) setState(() => _at = (_at + by + n) % n);
  }

  void _run() {
    final shown = _shown;
    if (_at < shown.length) Navigator.of(context).pop(shown[_at]);
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final shown = _shown;
    final at = shown.isEmpty ? 0 : _at.clamp(0, shown.length - 1);
    return Align(
      alignment: const Alignment(0, -0.6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: Material(
          key: const ValueKey('command palette'),
          color: k.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
          clipBehavior: Clip.antiAlias,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: (_) => setState(() => _at = 0),
                  onSubmitted: (_) => _run(),
                  decoration: const InputDecoration(hintText: 'Type a command…', isDense: true),
                ),
              ),
              Divider(height: 1, color: k.divider),
              Flexible(
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Nothing matches.', style: TextStyle(color: k.muted)),
                      )
                    : ListView(shrinkWrap: true, children: [
                        for (final (i, c) in shown.indexed)
                          Semantics(
                            button: true,
                            selected: i == at,
                            label: '${c.group}: ${c.label}',
                            onTap: () => Navigator.of(context).pop(c),
                            excludeSemantics: true,
                            child: InkWell(
                              onTap: () => Navigator.of(context).pop(c),
                              child: Container(
                                color: i == at ? k.fill : null,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(children: [
                                  Icon(c.icon, size: 16, color: c.danger ? k.removed : k.muted),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(c.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 13, color: c.danger ? k.removed : k.ink)),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(c.group, style: TextStyle(fontSize: 12, color: k.muted)),
                                ]),
                              ),
                            ),
                          ),
                      ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
