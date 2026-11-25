import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../data/deep_link.dart';
import '../data/host_store.dart';
import '../data/loose_agents.dart';
import '../main.dart';
import '../models.dart';
import 'chat_screen.dart';
import 'common.dart';
import 'desktop_shell.dart';
import 'loose_agent_screen.dart';
import 'needs_you_banner.dart';

/// Opens `pocketrig://seat/<session>?host=<name>` links from notifications:
/// switches to the named host, finds the seat, and opens it. Both the chat
/// and the terminal show the native permission card while the seat waits.
class DeepLinks {
  DeepLinks(this.store, this.navigator);
  final HostStore store;
  final GlobalKey<NavigatorState> navigator;
  StreamSubscription<Uri>? _sub;

  void start() {
    final links = AppLinks();
    links.getInitialLink().then((u) {
      if (u != null) handle(u);
    }).catchError((_) {});
    _sub = links.uriLinkStream.listen(handle, onError: (_) {});
  }

  void dispose() => _sub?.cancel();

  Future<Host?> _switchTo(String? hint) async {
    final host = hint == null ? store.active : store.hosts.where((h) => h.matchesHint(hint)).firstOrNull ?? store.active;
    if (host == null) return null;
    // A link from a host that is off opens nothing: falling back to the active host would open the same session
    // name on the wrong machine.
    final off = hint == null ? null : store.all.where((h) => !h.enabled && h.matchesHint(hint)).firstOrNull;
    if (off != null && !store.hosts.any((h) => h.matchesHint(hint!))) {
      final ctx = navigator.currentContext;
      if (ctx != null && ctx.mounted) toast(ctx, '${off.name} is off');
      return null;
    }
    if (host.id != store.active?.id) await store.select(host.id);
    return host;
  }

  /// An agent outside a rig: find it among the loose agents, or open what
  /// the link says about it.
  Future<void> _openAgent(AgentLink link) async {
    final host = await _switchTo(link.host);
    if (host == null) return;
    await WidgetsBinding.instance.endOfFrame;
    final ctx = navigator.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final api = AppScope.clientOf(ctx);
    if (api == null) return;
    var rigs = <RigWithSeats>[];
    LooseAgent? agent;
    try {
      rigs = await api.rigsWithSeats();
      final all = await loadLooseAgents(host, api, rigs);
      agent = all.where((a) => a.claudeSessionId == link.id || (link.tmux != null && a.tmuxSession == link.tmux)).firstOrNull;
    } catch (e) {
      if (ctx.mounted) toast(ctx, 'Couldn\'t reach ${host.name}: $e');
    }
    agent ??= LooseAgent(
        id: link.tmux ?? link.id, claudeSessionId: link.id, runtime: 'claude-code', tmuxSession: link.tmux, cwd: link.cwd);
    final a = agent;
    if (shownDetailPane() ?? navigator.currentState case final nav?) openLooseAgent(nav, a, rigs);
  }

  Future<void> handle(Uri uri) async {
    final agentLink = AgentLink.parse(uri);
    if (agentLink != null) return _openAgent(agentLink);
    final link = SeatLink.parse(uri);
    if (link == null) return;
    final host = await _switchTo(link.host);
    if (host == null) return;
    // Let AppScope rebuild with the new host before asking it for a client.
    await WidgetsBinding.instance.endOfFrame;
    final ctx = navigator.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final api = AppScope.clientOf(ctx);
    if (api == null) return;

    Seat? seat;
    String rigName = link.rigName ?? '';
    try {
      for (final r in await api.rigsWithSeats()) {
        final s = r.seats.where((s) => s.sessionName == link.session).firstOrNull;
        if (s != null) {
          seat = s;
          rigName = r.rig.name;
          break;
        }
      }
    } catch (e) {
      if (ctx.mounted) toast(ctx, 'Couldn\'t reach ${host.name}: $e');
    }
    final target = seat ?? Seat(rigId: '', logicalId: link.logicalId, sessionName: link.session);
    final screen = seatScreen(rigName, target);
    if (shownDetailPane() case final pane?) {
      unawaited(pane.push(MaterialPageRoute<void>(builder: (_) => screen)));
      return;
    }
    final nav = navigator.currentState;
    if (nav == null) return;
    openSeatScreen(nav, screen);
  }
}
