import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import 'terminal_style.dart';

import '../data/fleet.dart';
import '../data/host_store.dart' show isDesktop;
import '../data/seat_poll.dart';
import '../main.dart';
import '../models.dart';
import '../terminal/terminal_link.dart';
import '../terminal/tmux_scroll.dart';
import '../terminal/links.dart';
import '../terminal/transport.dart';
import 'action_rows.dart' show showActionRows;
import 'rig/seat_actions.dart' show seatMenuRows;
import 'rig/seat_sheet.dart' show showSeatSheet;
import 'agent_panels.dart' show AgentMediaCounts, AgentPanelsToggle, PanelPreviewHost;
import 'common.dart' show toast;
import 'file_drop.dart';
import 'agent_header.dart' show AgentHeader;
import 'agent_view_switch.dart' show AgentView, agentViews;
import 'chat_screen.dart' show ChatScreen, seatScreen;
import 'desktop_shell.dart' show seatPanelKey, showsInPanel;
import 'rig/rig_bar.dart' show RigBar;
import 'rig/rig_host.dart' show RigHost, RigHostState;
import 'rig_screen.dart' show RigScreen;
import 'progress_bar.dart' show ContextBar;
import 'usage_strip.dart' show contextColor, contextWeight;
import 'status_shape.dart';
import 'terminal_screen.dart' show shiftEnterNewline;
import 'theme.dart';

/// Opens the tiles in the content panel (the whole window on a narrow desktop).
/// A rig's first screen: on desktop a running rig's tiles; on the phone its details (never the tiles), with [enlarge]'s
/// agent opened over them as chat (a Claude agent) or terminal.
Widget rigHome(RigWithSeats r, String projectName, {String? enlarge, Key? key}) {
  if (r.rig.status != 'stopped' && isDesktop) {
    return RigHost(key: key, rig: r.rig, seats: r.seats, projectName: projectName, enlarge: enlarge);
  }
  final seat = r.seats.where((s) => TilesScreen.tiled(s) && s.logicalId == enlarge).firstOrNull;
  return seat == null || r.rig.status == 'stopped' ? RigScreen(rig: r.rig, projectName: projectName) : seatScreen(r.rig.name, seat);
}

/// Asks the tiles of rig `rigId` on top of the content panel to enlarge `seat`. Tiles that take it set it back to
/// null; a request still set after [tilesEnlarge] returns found no such tiles.
final enlargeRequest = ValueNotifier<({String rigId, String seat})?>(null);

/// Enlarges [seat] in its rig's tiles when they are on top of the content panel; false when they aren't.
bool tilesEnlarge(String rigId, String seat) {
  enlargeRequest.value = (rigId: rigId, seat: seat);
  final taken = enlargeRequest.value == null;
  enlargeRequest.value = null;
  return taken;
}

/// An agent's terminal from a chat on the Mac: when the rig's tiles are alive (its host is on a route under this chat) the tile
/// enlarges and this chat goes, so the agent keeps its one client; false when there are no such tiles (open a terminal screen).
bool terminalInTile(BuildContext context, Seat seat) {
  final host = RigHostState.liveFor(seat.rigId);
  if (!isDesktop || !TilesScreen.tiled(seat) || host == null) return false;
  // Back to the host, past anything between it and this chat (Agent details...).
  final route = host.route;
  Navigator.of(context).popUntil((r) => r == route || r.isFirst);
  // After the chat has left, the tiles' route is the current one and takes the request.
  WidgetsBinding.instance.addPostFrameCallback((_) => tilesEnlarge(seat.rigId, seat.logicalId));
  return true;
}

/// Every running agent of a rig as a live terminal in one grid (desktop). Each tile reflows, resizing its agent's window
/// to the tile; a double click enlarges one, and another shrinks it back. [enlarge] opens with that seat enlarged.
class TilesScreen extends StatefulWidget {
  const TilesScreen({super.key, required this.rig, required this.seats, required this.projectName, this.enlarge});
  final Rig rig;
  final String projectName;
  final List<Seat> seats;
  final String? enlarge;

  /// The seats with a tile: running agents with a session.
  static bool tiled(Seat s) => s.isAgent && s.sessionName != null && s.state != SeatState.stopped;
  @override
  State<TilesScreen> createState() => _TilesScreenState();
}

class _TilesScreenState extends State<TilesScreen> with SingleTickerProviderStateMixin {
  late List<Seat> _seats = widget.seats.where(TilesScreen.tiled).toList();
  Timer? _poll;
  late String? _enlarged = widget.enlarge, _focused = widget.enlarge;

  /// Enlarging grows the tile out of its grid cell and shrinking puts it back, over the others as they fade: the
  /// layout jumps to its end at once (the agent's window resizes once) and a transform carries the tile there.
  late final _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _moving = null);
    });
  late final _eased = _flip.drive(CurveTween(curve: kEaseOut));
  String? _moving;
  bool _growing = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(seatPollEvery, (_) => _refresh());
    enlargeRequest.addListener(_onEnlargeRequest);
  }

  void _onEnlargeRequest() {
    final r = enlargeRequest.value;
    if (r == null || r.rigId != widget.rig.id || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    enlargeRequest.value = null;
    _enlarge(r.seat);
  }

  void _enlarge(String? seat) {
    final from = _enlarged;
    if (seat == from) return;
    setState(() {
      _focused = seat ?? from;
      _enlarged = seat;
      // One agent enlarged in place of another just swaps.
      _moving = from == null || seat == null ? seat ?? from : null;
      _growing = seat != null;
    });
    if (_moving == null || MediaQuery.disableAnimationsOf(context)) {
      _flip.value = 1;
      _moving = null;
    } else {
      _flip.forward(from: 0);
    }
  }

  @override
  void dispose() {
    enlargeRequest.removeListener(_onEnlargeRequest);
    _flip.dispose();
    _poll?.cancel();
    super.dispose();
  }

  /// Behind the rig page (a host keeps the tiles alive, tickers off) the poll waits; coming back refreshes at once.
  bool _shown = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shown = TickerMode.valuesOf(context).enabled;
    final back = shown && !_shown;
    _shown = shown;
    if (back) _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || !_shown) return;
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final all = await api.seats(widget.rig.id);
      if (mounted) {
        if (AppScope.read(context).active case final host?) fleet.feedFor(host).applyShells(all);
      }
      final seats = all.where(TilesScreen.tiled).toList();
      if (mounted) setState(() => _seats = seats);
    } catch (_) {/* keep the last known seats */}
  }

  /// Each tile's state, so the agent row over an enlarged one can open the tile's own ⋯ list.
  final _tileKeys = <String, GlobalKey<_TileState>>{};

  void _toggle(Seat s) {
    _enlarge(_enlarged == s.logicalId ? null : s.logicalId);
  }

  Widget _agentRow(BuildContext context, Seat s) {
    final cwd = s.cwd;
    return AgentHeader(
      seat: s,
      title: s.logicalId,
      subtitle: Text(cwd == null ? widget.rig.name : '${widget.projectName} › ${widget.rig.name}',
          style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis),
      menuTooltip: 'Actions for ${s.logicalId}',
      onMenu: () => _tileKeys[s.logicalId]?.currentState?._menu(),
      showing: AgentView.terminal,
      views: agentViews(s),
      onSwitch: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ChatScreen(rigName: widget.rig.name, seat: s, asChat: true))),
      extraActions: const [AgentPanelsToggle()],
      showBack: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final enlarged = _seats.indexWhere((s) => s.logicalId == _enlarged);
    // The sidebar marks the enlarged agent, else the rig.
    // Only while the tiles are the screen on show: behind the rig page (a host keeps them alive) they leave the sidebar alone.
    if (_shown) showsInPanel(context, enlarged >= 0 ? seatPanelKey(_seats[enlarged]) : 'rig:${widget.rig.id}');
    final n = _seats.length;
    final cols = n == 0 ? 1 : math.sqrt(n).ceil();
    final rows = n == 0 ? 1 : (n / cols).ceil();
    Widget tile(Seat s, {required bool big}) => _Tile(
          key: _tileKeys.putIfAbsent(s.logicalId, () => GlobalKey<_TileState>()),
          rigName: widget.rig.name,
          seat: s,
          big: big,
          focused: _focused == s.logicalId,
          visible: big || enlarged < 0,
          onFocus: () => setState(() => _focused = s.logicalId),
          onToggle: () => _toggle(s),
        );
    return Scaffold(
      backgroundColor: k.termBg,
      body: Column(children: [
        // The rig's fixed row, the one the page and the chat have; Rig details opens the page in this screen's place.
        RigBar(rig: widget.rig, seats: _seats, projectName: widget.projectName, showBack: true),
        // An enlarged tile is the agent's full terminal: its row (name at the left; Chat | Terminal, the panels toggle and ⋯ at the
        // right) under the rig's, with the dock beside the terminal.
        if (enlarged >= 0) _agentRow(context, _seats[enlarged]),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            // One flat list keyed by seat: a tile keeps its connection when the grid changes shape, and enlarging only
            // resizes it, so each agent has one client and its window follows the tile. The others stay connected, hidden.
            child: LayoutBuilder(
              builder: (context, box) {
                Rect cell(int i) => Rect.fromLTWH(i % cols * box.maxWidth / cols, i ~/ cols * box.maxHeight / rows,
                    box.maxWidth / cols, box.maxHeight / rows);
                final full = Offset.zero & box.biggest;
                final moving = _seats.indexWhere((s) => s.logicalId == _moving);
                Widget place(int i) {
                  final to = i == enlarged ? full : cell(i);
                  final from = _growing ? cell(i) : full;
                  // The same wrappers every frame, moving or not: a changed tree would reconnect the tile.
                  final child = FadeTransition(
                    // The rest fade out under the growing tile, back in under the shrinking one.
                    opacity: moving < 0 || i == moving
                        ? kAlwaysCompleteAnimation
                        : _growing
                            ? ReverseAnimation(_eased)
                            : _eased,
                    child: AnimatedBuilder(
                      animation: _eased,
                      child: Padding(padding: const EdgeInsets.all(3), child: tile(_seats[i], big: i == enlarged)),
                      builder: (_, child) {
                        final r = i == moving ? Rect.lerp(from, to, _eased.value)! : to;
                        return Transform(
                          transform: Matrix4.translationValues(r.left - to.left, r.top - to.top, 0)
                              .multiplied(Matrix4.diagonal3Values(r.width / to.width, r.height / to.height, 1)),
                          child: child,
                        );
                      },
                    ),
                  );
                  return Positioned.fromRect(
                    key: ValueKey(_seats[i].logicalId),
                    rect: to,
                    child: Offstage(offstage: enlarged >= 0 && i != enlarged && moving < 0, child: child),
                  );
                }

                // The moving tile paints over the others.
                return Stack(children: [
                  for (var i = 0; i < n; i++)
                    if (i != moving) place(i),
                  if (moving >= 0) place(moving),
                ]);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _Tile extends StatefulWidget {
  const _Tile(
      {super.key,
      required this.rigName,
      required this.seat,
      required this.big,
      required this.focused,
      required this.visible,
      required this.onFocus,
      required this.onToggle});
  final String rigName;
  final Seat seat;
  final bool big;
  final bool focused;

  /// On screen: false for the grid's tiles while one is enlarged.
  final bool visible;
  final VoidCallback onFocus;
  final VoidCallback onToggle;
  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  final _terminal = Terminal(maxLines: 5000);
  final _focus = FocusNode();
  TerminalTransport? _transport;
  TerminalLink? _link;
  String? _error;
  Duration? _lastDown;

  late final _scroll = TmuxScroller(
      session: widget.seat.sessionName,
      host: () => AppScope.read(context).active,
      onError: (m) {
        if (mounted) toast(context, m);
      });

  void _input(String data) => switch (_transport) {
        final t? => _scroll.send(t.sendRaw, data),
        null => null,
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _connect();
    });
  }

  @override
  void didUpdateWidget(_Tile old) {
    super.didUpdateWidget(old);
    // Back from the enlarged view: the typing goes to the tile it came from.
    if (widget.visible && widget.focused && (widget.big != old.big || !old.visible)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _link?.close();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _error = null);
    try {
      // A tile reflows: it resizes its agent's window to the tile, as the single desktop terminal does (the one shared connect).
      final link = await connectTerminal(host, SeatTarget(widget.rigName, widget.seat), _terminal,
          onInput: _input, alive: () => mounted, onError: (m) => setState(() => _error = m));
      if (link == null) return;
      _link = link;
      setState(() => _transport = link.transport);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// The agent's ⋯ list, the one its header has: Open as chat / terminal (the tile enlarges), Agent details, Reconnect...
  void _menu() {
    final seat = widget.seat;
    final reconnect = (Icons.refresh_outlined, 'Reconnect', null, _reconnect);
    showActionRows(
        context,
        seat.logicalId,
        seatMenuRows(context, widget.rigName, seat,
            onTerminal: widget.onToggle,
            extra: [reconnect],
            onDetails: () => showSeatSheet(context, widget.rigName, seat,
                onTerminal: widget.onToggle, extraActions: [(reconnect.$1, reconnect.$2, _reconnect)])));
  }

  Future<void> _reconnect() async {
    await _link?.close();
    _link = null;
    if (mounted) setState(() => _transport = null);
    await _connect();
  }

  /// A second press within 300 ms is a double click; a Listener sees it without taking the terminal's own taps. A
  /// right click does nothing (the ⋯ is the menu, and the terminal does not send it to tmux either).
  void _down(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) return;
    widget.onFocus();
    _focus.requestFocus();
    // The pointer's own timestamp, not the wall clock: a loaded machine can't stretch two quick presses apart.
    final now = e.timeStamp;
    final double = _lastDown != null && now - _lastDown! < const Duration(milliseconds: 300);
    _lastDown = double ? null : now;
    if (double) widget.onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    // The dock sits outside the tile's Listener: clicks in it don't count toward a double click.
    return PanelPreviewHost(seat: widget.big ? widget.seat : null, focus: _focus, child: Listener(
      onPointerDown: _down,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Status.of(widget.seat.state).termBg(k),
          border: Border.all(
              color: Status.of(widget.seat.state).edge(k) ?? (widget.focused ? k.ink : k.border),
              width: widget.focused ? 2 : 1),
        ),
        // Square corners: the rough terminal look.
        child: ClipRect(
          child: Column(children: [
            if (!widget.big) LayoutBuilder(builder: (context, box) => Container(
              height: 28,
              color: k.ground,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                StatusShape(Status.of(widget.seat.state), size: 9, semantics: false),
                const SizedBox(width: 6),
                Expanded(
                  // Working, on a shell or waiting on you: the name in that color, bold.
                  child: Text(widget.seat.logicalId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(context,
                          size: 13,
                          color: Status.of(widget.seat.state).edge(k) ?? k.ink,
                          weight: Status.of(widget.seat.state).edge(k) == null ? FontWeight.w400 : FontWeight.w700)),
                ),
                if (_error != null) Text(_error!, maxLines: 1, style: TextStyle(fontSize: 11, color: k.muted)),
                // At its usage limit (OpenRig 0.7.22+): the words, in muted red, before the counts.
                if (usageLimitLine(widget.seat) case final limit?)
                  Flexible(
                    flex: 0,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(limit, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: limitColor(k))),
                    ),
                  ),
                AgentMediaCounts(seat: widget.seat),
                // Context in use, after the counts. Unknown: nothing (no 0%, no empty bar).
                if (widget.seat.contextUsedPercent case final ctx?) _TileContext(ctx, bar: box.maxWidth >= 260),
                // The agent's actions, the list its header's ⋯ opens: the way in (a right click does nothing).
                IconButton(
                  tooltip: 'Actions for ${widget.seat.logicalId}',
                  onPressed: _menu,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                  style: IconButton.styleFrom(minimumSize: const Size(24, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  icon: Icon(Icons.more_horiz, size: 16, color: k.muted),
                ),
              ]),
            )),
            Expanded(
              child: Builder(builder: (context) {
                const pad = 2.0;
                const size = 12.0;
                final line = size * terminalStyle(1).height;
                return Stack(children: [
                  Positioned.fill(child: Listener(
                    // The wheel, a trackpad swipe or a finger scroll tmux's history, as in the single terminal.
                    onPointerMove: (e) => _scroll.onPointerMove(e, line),
                    onPointerSignal: (e) => _scroll.onPointerSignal(e, line),
                    onPointerPanZoomUpdate: (e) => _scroll.onPanZoomUpdate(e, line),
                    child: ImageDropTarget(onPaste: (p) => _terminal.paste(quotedPaths(p)), child: TerminalView(
                  _terminal,
                  focusNode: _focus,
                  autoResize: true,
                  autofocus: widget.big,
                  theme: TerminalThemes.defaultTheme,
                  backgroundOpacity: 0,
                  textStyle: terminalStyle(size),
                  padding: const EdgeInsets.all(pad),
                  simulateScroll: false,
                  onTapUp: (d, cell) => openLinkOnModClick(_terminal, d, cell),
                  onKeyEvent: shiftEnterNewline(_input),
                )))),
                  // Scrolled back into tmux's history: the way back to the live output (typing does it too), as in the single terminal.
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _scroll.inCopyMode,
                      builder: (context, back, _) => !back
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              onPressed: _scroll.toLive,
                              icon: const Icon(Icons.arrow_downward, size: 18),
                              label: const Text('Back to live'),
                            ),
                    ),
                  ),
                ]);
              }),
            ),
          ]),
        ),
      ),
      ));
  }
}

/// A tile header's context in use: the % in mono, then a 36dp bar. On a narrow tile the bar goes first and the number stays.
class _TileContext extends StatelessWidget {
  const _TileContext(this.percent, {required this.bar});
  final double percent;
  final bool bar;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      label: 'context ${percent.round()} percent used',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${percent.round()}%',
              style: mono(context, size: 11, color: contextColor(percent, k)).copyWith(fontWeight: contextWeight(percent))),
          if (bar) ...[const SizedBox(width: 6), SizedBox(width: 36, child: ContextBar(percent, height: 3, label: false))],
        ]),
      ),
    );
  }
}
