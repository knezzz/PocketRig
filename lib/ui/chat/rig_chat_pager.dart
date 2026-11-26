import 'package:flutter/material.dart';

import '../../data/fleet.dart' show fleet;
import '../../data/git_status.dart';
import '../../data/host_store.dart' show isDesktop;
import '../../main.dart' show AppScope;
import '../../models.dart';
import '../../terminal/transport.dart';
import '../chat_screen.dart';
import '../agent_panels.dart' show AgentPanelsToggle, PanelPreviewHost;
import '../agent_view_switch.dart';
import '../needs_you_banner.dart';
import '../project_actions.dart' show projectNameOf;
import '../rig/rig_bar.dart' show RigBar;
import '../terminal_screen.dart';
import '../rig/rig_host.dart' show RigMode, rigRoute;
import '../tiles_screen.dart' show TilesScreen, terminalInTile;
import '../theme.dart';
import 'chat_header.dart';
import 'seat_switcher.dart';

/// What the page on screen tells the pager's header: its subtitle, git bar, the rig's agents (for the tabs) and menu.
class ChatHeaderInfo {
  const ChatHeaderInfo(
      {required this.seatId, required this.subtitle, required this.git, required this.rigSeats, required this.onMenu});
  final String seatId;
  final String subtitle;
  final GitStatus? git;
  final List<Seat> rigSeats;
  final VoidCallback onMenu;

  bool sameAs(ChatHeaderInfo o) =>
      seatId == o.seatId && subtitle == o.subtitle && identical(git, o.git) && sameSeatStates(rigSeats, o.rigSeats);
}

/// A rig agent's chat as one screen: the header (back, name, menu, tabs) stays, and the conversation below slides
/// between the rig's Claude agents, by tapping a tab or swiping. Only the page that has settled on screen opens its
/// log and polls; a page swiped away is dropped (its composer text is kept here). A tab for an agent that isn't
/// Claude replaces this screen with its terminal, as before.
class RigChatPager extends StatefulWidget {
  const RigChatPager({super.key, required this.rigName, required this.seat});
  final String rigName;
  final Seat seat;
  @override
  State<RigChatPager> createState() => _RigChatPagerState();
}

class _RigChatPagerState extends State<RigChatPager> {
  /// Every agent of the rig, for the tabs; and the Claude ones among them, which are the pages.
  late List<Seat> _tabs = [widget.seat];
  late String _selected = widget.seat.logicalId;
  late String _settled = widget.seat.logicalId;
  late final _controller = PageController();
  final _header = ValueNotifier<ChatHeaderInfo?>(null);
  final _drafts = <String, TextEditingController>{};
  Route<dynamic>? _route;

  /// The seat this chat was opened for is always a page, whatever runs in it.
  List<Seat> get _pages => [for (final s in _tabs) if (s.isClaude || s.logicalId == widget.seat.logicalId) s];
  int get _index => _pages.indexWhere((s) => s.logicalId == _selected).clamp(0, _pages.length - 1);

  @override
  void initState() {
    super.initState();
    _header.addListener(_onHeader);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    seatScreenRoutes.remove(_route);
    _route = ModalRoute.of(context);
    if (_route != null) seatScreenRoutes.add(_route!);
  }

  @override
  void dispose() {
    seatScreenRoutes.remove(_route);
    _header
      ..removeListener(_onHeader)
      ..dispose();
    _controller.dispose();
    for (final c in _drafts.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onHeader() {
    final info = _header.value;
    if (info != null && info.seatId == _settled && info.rigSeats.isNotEmpty) _setTabs(info.rigSeats);
    if (mounted) setState(() {});
  }

  /// Takes the rig's agents, keeping the one on screen even if it dropped out of the list.
  void _setTabs(List<Seat> agents) {
    if (sameSeatStates(agents, _tabs)) return;
    final keep = _tabs.where((s) => s.logicalId == _selected).firstOrNull;
    final next = [...agents];
    if (keep != null && !next.any((s) => s.logicalId == _selected)) next.add(keep);
    final before = _index;
    setState(() => _tabs = next);
    // A page inserted before this one moves it: stay on it.
    if (_index != before && _controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpToPage(_index);
      });
    }
  }

  /// The terminal takes this screen's place (not a page over it): Back leaves the agent.
  void _toTerminal(Seat s) {
    // The rig's tiles are alive: that agent's terminal is its tile, enlarged (one client).
    if (terminalInTile(context, s)) return;
    switchAgentView(
      context,
      (_) => TerminalScreen(target: SeatTarget(widget.rigName, s)),
      session: s.sessionName,
    );
  }

  /// The rig this chat belongs to, with its seats, from the host's feed.
  RigWithSeats? _rigWithSeats(BuildContext context) {
    final host = AppScope.of(context).active;
    return host == null ? null : fleet.feedFor(host).rigs.where((r) => r.rig.id == widget.seat.rigId).firstOrNull;
  }

  void _tapTab(Seat s) {
    if (s.logicalId == _selected) return;
    if (!s.isClaude && s.logicalId != widget.seat.logicalId) {
      // A non-Claude agent has no chat: on the Mac its terminal is its tile in the rig's host, enlarged, with the rig's row; a
      // host that is alive is gone back to, else this chat gives way to a new one.
      if (terminalInTile(context, s)) return;
      final rig = _rigWithSeats(context);
      if (isDesktop && rig != null && rig.rig.status != 'stopped' && TilesScreen.tiled(s)) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => rigRoute(rig.rig, projectNameOf(rig.primaryCwd ?? rig.rig.name),
                seats: rig.seats, mode: RigMode.tiles, enlarge: s.logicalId)));
        return;
      }
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => TerminalScreen(target: SeatTarget(widget.rigName, s))));
      return;
    }
    final i = _pages.indexWhere((p) => p.logicalId == s.logicalId);
    if (i >= 0) {
      _controller.animateToPage(i, duration: const Duration(milliseconds: 280), curve: kEaseOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final info = _header.value?.seatId == _selected ? _header.value : null;
    final git = info?.git;
    // The Mac: this rig's page one click away (a stopped rig has only the page).
    final r = _rigWithSeats(context);
    return Scaffold(
      body: Column(children: [
        // The Mac: the rig's own fixed row above the agent's header.
        // Its Back is the screen's (as on the page and the tiles, so the icon and title do not move); the agent row has none.
        if (isDesktop && r != null)
          RigBar(rig: r.rig, seats: r.seats, projectName: projectNameOf(r.primaryCwd ?? r.rig.name), showBack: true),
        chatAgentHeader(
          context,
          seat: _pages.where((s) => s.logicalId == _selected).firstOrNull,
          title: _selected,
          subtitle: info?.subtitle ?? widget.rigName,
          onMenu: info?.onMenu,
          onSwitch: () => _toTerminal(_pages.firstWhere((s) => s.logicalId == _selected)),
          git: git,
          onGit: (g) => showGitSheet(context, g),
          // The Mac: the panels toggle in the agent row, left of the Chat | Terminal switch.
          extraActions: [if (isDesktop) const AgentPanelsToggle()],
          showBack: !(isDesktop && r != null),
          tabs: _tabs.length > 1 ? SeatSwitcher(seats: _tabs, selected: _selected, onTap: _tapTab) : null,
        ),
        Expanded(
          // The dock and its previews beside the pages (the Mac), following the agent on show.
          child: PanelPreviewHost(
            seat: isDesktop ? _pages.where((s) => s.logicalId == _selected).firstOrNull : null,
            headerBack: Navigator.of(context).canPop(),
            // The page that has stopped moving is the one that runs: not the neighbour a drag is passing through.
            child: NotificationListener<ScrollEndNotification>(
            onNotification: (n) {
              if (n.depth != 0) return false;
              final settled = pages[_controller.page!.round().clamp(0, pages.length - 1)].logicalId;
              if (settled != _settled) setState(() => _settled = settled);
              return false;
            },
            child: PageView.builder(
              controller: _controller,
              itemCount: pages.length,
              onPageChanged: (i) {
                // A focused composer keeps its page alive offscreen and keeps the keyboard's typing; let it go.
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _selected = pages[i].logicalId);
              },
              findChildIndexCallback: (key) {
                final i = pages.indexWhere((s) => ValueKey(s.logicalId) == key);
                return i < 0 ? null : i;
              },
              itemBuilder: (_, i) {
                final seat = pages[i];
                return ChatPage(
                  key: ValueKey(seat.logicalId),
                  rigName: widget.rigName,
                  seat: seat,
                  embedded: true,
                  active: seat.logicalId == _settled,
                  draft: _drafts.putIfAbsent(seat.logicalId, TextEditingController.new),
                  header: _header,
                );
              },
            ),
          ),
          ),
        ),
      ]),
    );
  }
}

/// Whether two seat lists show the same tabs: the same agents in order, in the same states.
bool sameSeatStates(List<Seat> a, List<Seat> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i].logicalId == b[i].logicalId && a[i].state == b[i].state].every((x) => x);
