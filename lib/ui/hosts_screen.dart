import 'dart:async';

import 'package:flutter/material.dart';

import 'page_column.dart';
import '../data/usage_rings.dart';
import '../main.dart';
import 'agent_view_switch.dart' show AgentView;
import 'appearance.dart';
import 'debug_overlay_setting.dart';
import 'first_run.dart';
import 'option_sheet.dart';
import 'kit.dart';
import 'open_agents_on.dart';
import 'theme.dart';
import 'usage_strip.dart';
import '../data/chat_cache.dart';
import 'hosts/host_editor.dart';
import 'hosts/host_state_tile.dart';
export 'hosts/host_editor.dart' show HostEditor;
export 'hosts/host_state_tile.dart' show HostReach, HostStateTile, hostLastSeen;

/// The Settings tab: hosts (each with one honest state line) and the app's own settings. With no host yet, the
/// first-run steps instead. On a wide window the hosts are a list at the left with the selected host's editor beside it;
/// narrower, a tap pushes the editor.
class HostsScreen extends StatefulWidget {
  const HostsScreen({super.key});

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  /// The host whose editor is beside the list: a host's id, or [_adding]; null: the active host.
  String? _selected;
  static const _adding = '+';

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900 && store.all.isNotEmpty;
      final picked = _selected == _adding ? null : store.all.where((h) => h.id == (_selected ?? store.active?.id)).firstOrNull ?? store.all.firstOrNull;
      final adding = wide && _selected == _adding;
      final list = ListView(
        // On a wide window the list starts at the header's left edge (its title sits 12 in).
        padding: EdgeInsets.fromLTRB(wide ? 12 : 20, 16, 20, 24),
        children: [
          if (store.all.isEmpty)
            FirstRunSetup(
              onContinue: (draft) => HostEditor.open(context, null, draft: draft),
              onManual: () => HostEditor.open(context, null),
            )
          else ...[
            // Enabled hosts, then disabled ones; a group with no host is not shown. The hint says what Disabled does.
            for (final (i, (title, hosts)) in [
              ('Enabled', [for (final h in store.all) if (h.enabled) h]),
              ('Disabled', [for (final h in store.all) if (!h.enabled) h]),
            ].where((g) => g.$2.isNotEmpty).indexed)
              Section(
                title,
                gap: title == 'Enabled' && store.all.any((h) => !h.enabled) ? 22 : 0,
                trailing: wide || i > 0 ? null : _addHost(context, wide),
                children: [
                  for (final h in hosts)
                    HostStateTile(
                      key: ValueKey(h.id),
                      host: h,
                      active: h.id == store.active?.id,
                      onSelect: wide ? () => setState(() => _selected = h.id) : null,
                      selected: wide && !adding && picked?.id == h.id,
                    ),
                ],
              ),
          ],
          if (store.all.any((h) => !h.enabled))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Disabled hosts are not polled and their rigs are hidden from Rigs.',
                  style: TextStyle(fontSize: 12, color: Tokens.of(context).muted)),
            ),
          // On a wide window the usage lives in the sidebar and on the Rigs home; here it is the narrow layout's only place.
          if (!wide) const _UsageSection(),
          const SizedBox(height: 22),
          const _AppSection(),
        ],
      );
      return Scaffold(
        body: Column(children: [
          PageHeader(title: 'Hosts and settings', actions: [if (wide) _addHost(context, wide)]),
          Expanded(
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: list),
                    VerticalDivider(width: 1, color: Tokens.of(context).border),
                    SizedBox(
                      width: 460,
                      // Keyed by the host, so picking another starts its editor afresh.
                      child: HostEditor(
                        key: ValueKey(adding ? _adding : picked?.id),
                        host: adding ? null : picked,
                        onDone: () => setState(() => _selected = null),
                      ),
                    ),
                  ])
                : PageColumn(child: list),
          ),
        ]),
      );
    });
  }

  /// [wide] is the layout's own (the pane's width, not the window's): beside the list the editor opens in the pane, else pushed.
  Widget _addHost(BuildContext context, bool wide) => TextButton(
        onPressed: () => wide ? setState(() => _selected = _adding) : HostEditor.open(context, null),
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)).merge(compactAction),
        child: const Text('+ Add host', style: TextStyle(fontWeight: FontWeight.w600)),
      );
}

/// Usage, moved here from the top of the tabs: shown once there are readings.
class _UsageSection extends StatelessWidget {
  const _UsageSection();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, readings, _) {
          final any = UsageRing.from(readings).isNotEmpty;
          // The strip is always mounted (keyed, so it stays one element): it fetches the readings when they are stale.
          return Padding(
            padding: EdgeInsets.only(top: any ? 18 : 0),
            child: Section(any ? 'Usage' : null, child: const UsageStrip(key: ValueKey('usage'))),
          );
        },
      );
}

/// One plain settings row: label, value, an optional control.
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, this.value, this.trailing, this.onTap});
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return RowTile(
      minHeight: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      onTap: onTap,
      arrow: trailing == null,
      trailing: trailing,
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 15))),
        if (value != null) Text(value!, style: TextStyle(fontSize: 13, color: k.muted)),
      ]),
    );
  }
}

/// Settings › App: saved chats, pinned folders, appearance, the debug overlay.
class _AppSection extends StatelessWidget {
  const _AppSection();

  Future<void> _pickAppearance(BuildContext context) async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (_) => OptionSheet<ThemeMode>(
        title: 'Appearance',
        current: appearance.value,
        options: [for (final m in const [ThemeMode.system, ThemeMode.light, ThemeMode.dark]) (m, appearanceLabel(m), null)],
      ),
    );
    if (picked != null) await setAppearance(picked);
  }

  Future<void> _pickOpenOn(BuildContext context) async {
    final picked = await showModalBottomSheet<AgentView>(
      context: context,
      showDragHandle: true,
      builder: (_) => OptionSheet<AgentView>(
        title: 'Open agents on',
        current: openAgentsOn.value,
        options: [for (final v in AgentView.values) (v, openAgentsOnLabel(v), null)],
      ),
    );
    if (picked != null) await setOpenAgentsOn(picked);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final pinned = store.hosts.fold<int>(0, (n, h) => n + h.pinnedFolders.length);
    return Section('App', children: [
      if (chatCache != null) _ChatCacheRow(chatCache!),
      _SettingRow(label: 'Pinned folders', value: '$pinned'),
      ValueListenableBuilder(
        valueListenable: appearance,
        builder: (context, mode, _) =>
            _SettingRow(label: 'Appearance', value: appearanceLabel(mode), onTap: () => _pickAppearance(context)),
      ),
      ValueListenableBuilder(
        valueListenable: openAgentsOn,
        builder: (context, v, _) =>
            _SettingRow(label: 'Open agents on', value: openAgentsOnLabel(v), onTap: () => _pickOpenOn(context)),
      ),
      ValueListenableBuilder(
        valueListenable: debugOverlay,
        builder: (context, on, _) => _SettingRow(
          label: 'Debug overlay',
          trailing: Switch(value: on, onChanged: setDebugOverlay),
        ),
      ),
    ]);
  }
}

/// How much the saved chats take, and a way to drop them after asking.
class _ChatCacheRow extends StatefulWidget {
  const _ChatCacheRow(this.cache);
  final ChatCache cache;

  @override
  State<_ChatCacheRow> createState() => _ChatCacheRowState();
}

class _ChatCacheRowState extends State<_ChatCacheRow> {
  late final _usage = widget.cache.watchUsage();

  Future<void> _clear(int chats) async {
    final ok = await confirmSheet(context,
        title: 'Clear $chats saved ${chats == 1 ? 'chat' : 'chats'}?',
        body: 'Removes the copies kept on this device. Nothing changes on your hosts; '
            'a chat loads again from its host when you open it.',
        action: 'Clear');
    if (ok) await widget.cache.clear();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<(int, int)>(
        stream: _usage,
        builder: (context, snap) {
          final (bytes, chats) = snap.data ?? (0, 0);
          final limit = widget.cache.maxTotalBytes ~/ (1024 * 1024);
          return _SettingRow(
            label: 'Saved chats',
            value: '${(bytes / (1024 * 1024)).toStringAsFixed(1)} of $limit MB · $chats',
            trailing: OutlinedButton(
              onPressed: chats == 0 ? null : () => _clear(chats),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)).merge(compactAction),
              child: const Text('Clear…'),
            ),
          );
        },
      );
}
