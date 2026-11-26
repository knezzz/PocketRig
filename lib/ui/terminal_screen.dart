import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'terminal_style.dart';

import '../main.dart';
import '../data/projects.dart' show projectShellSession;
import '../data/seat_poll.dart';
import '../models.dart';
import '../terminal/keys.dart';
import '../terminal/terminal_link.dart';
import '../terminal/tmux_scroll.dart';
import '../terminal/links.dart';
import '../terminal/transport.dart';
import 'agent_header.dart';
import 'agent_view_switch.dart';
import 'agent_panels.dart';
import 'agent_panels_sheet.dart' show PanelsStrip;
import '../data/host_store.dart' show isDesktop;
import 'chat_screen.dart';
import 'common.dart';
import 'needs_you_banner.dart';
import 'project_actions.dart' show confirmCloseShell, renameShellLabel;
import 'needs_you_strip.dart';
import 'rig/seat_sheet.dart' show showSeatSheet;
import 'kit.dart';
import 'status_shape.dart';
import 'desktop_shell.dart' show seatPanelKey, showsInPanel;
import 'theme.dart';
import 'tiles_screen.dart';

/// Shift+Enter types a newline instead of submitting: ESC CR, which Claude Code binds (its /terminal-setup).
FocusOnKeyEventCallback shiftEnterNewline(void Function(String) send) => (node, event) {
      if (event is KeyUpEvent ||
          event.logicalKey != LogicalKeyboardKey.enter ||
          !HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored;
      }
      send('\x1b\r');
      return KeyEventResult.handled;
    };

/// A seat's (or a project shell's) live pane (board Terminal). It and the chat take each other's place, so Back leaves the agent.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen(
      {super.key,
      required this.target,
      this.loose,
      this.rigs = const []});
  final TerminalTarget target;
  /// An agent outside a rig, kept for its chat: the chat's menu needs it (and the rigs it could join).
  final LooseAgent? loose;
  final List<RigWithSeats> rigs;


  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 5000);
  final _focus = FocusNode();
  final _selection = TerminalController();
  TerminalTransport? _transport;
  TerminalLink? _link;
  String? _error;

  /// Sticky modifiers from the key bar: they apply to the next key, typed
  /// or tapped. A double tap locks one on until it's tapped again.
  final Set<TermMod> _mods = {};
  final Set<TermMod> _locked = {};

  /// Live copy of the seat, polled so the permission card appears and
  /// disappears with the prompt.
  Seat? _seat;

  /// The key area: the phone keyboard and the extra keys,
  /// hidden and shown together. The phone's terminal starts without them: a tap on it, or on the key row, opens both.
  bool _keysOpen = isDesktop;

  void _hideKeys() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _keysOpen = false);
  }

  /// esc, tab, ctrl, ↑, ↓ and Enter (enough to answer a menu or drive a TUI), always there, and the Keyboard button, which is
  /// Hide while the keyboard is up (its extra keys, ← → among them, sit in a row above this one).
  Widget _collapsedKeys(Tokens k) {
    Widget key(String label, String spoken, String seq, {int flex = 1, IconData? icon, TermMod? mod}) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Semantics(
              button: true,
              label: spoken,
              toggled: mod == null ? null : _mods.contains(mod),
              onTap: () => mod == null ? _input(seq) : _toggleMod(mod),
              excludeSemantics: true,
              child: TextButton(
                onPressed: () => mod == null ? _input(seq) : _toggleMod(mod),
                style: TextButton.styleFrom(
                  minimumSize: const Size(28, 44),
                  padding: EdgeInsets.zero,
                  backgroundColor: mod != null && _mods.contains(mod) ? k.ink : k.ground,
                  foregroundColor: mod != null && _mods.contains(mod) ? k.onInk : k.ink,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadius),
                      side: mod != null && _locked.contains(mod) ? BorderSide(color: k.added, width: 2) : BorderSide.none),
                ),
                // The Enter symbol is in neither bundled font (it drew as a box): its own icon.
                child: icon == null
                    ? Text(label, style: const TextStyle(fontFamily: fontMono, fontSize: 14))
                    : Icon(icon, size: 18),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(children: [
        key('esc', 'Escape', '\x1b'),
        key('tab', 'Tab', '\t'),
        key('ctrl', 'Control', '', mod: TermMod.ctrl),
        key('↑', 'Up arrow', '\x1b[A'),
        key('↓', 'Down arrow', '\x1b[B'),
        key('enter', 'Enter', '\r', icon: Icons.keyboard_return),
        const SizedBox(width: 4),
        TextButton.icon(
          onPressed: _keysOpen ? _hideKeys : _showKeys,
          icon: Icon(_keysOpen ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined, size: 20),
          label: Text(_keysOpen ? 'Hide' : 'Keyboard'),
          style: TextButton.styleFrom(foregroundColor: k.ink),
        ),
      ]),
    );
  }

  void _showKeys() {
    setState(() => _keysOpen = true);
    _focus.requestFocus();
  }

  Timer? _seatPoll;
  late final _scroll = TmuxScroller(
      session: _tmuxSession,
      host: () => AppScope.read(context).active,
      onError: (m) {
        if (mounted) toast(context, m);
      });

  /// The tmux session on screen: the seat's, or the project shell's.
  String? get _tmuxSession => switch (widget.target) {
        SeatTarget(:final seat) => seat.sessionName,
        ProjectShellTarget(:final path) => projectShellSession(path),
      };

  /// Sends to the program, leaving copy mode first when a scroll put the pane in it.
  void _send(String data) => switch (_transport) {
        final t? => _scroll.send(t.sendRaw, data),
        null => null,
      };

  @override
  void initState() {
    super.initState();
    needsYouAlerts.focusedSession =
        (widget.target is SeatTarget ? (widget.target as SeatTarget).seat.sessionName : null);
    final target = widget.target;
    if (target is SeatTarget) _seat = target.seat;
    _selection.addListener(() {
      if (mounted) setState(() {});
    });
    _focus.addListener(() {
      if (_focus.hasFocus && !_keysOpen && mounted) setState(() => _keysOpen = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _connect();
      if (target is SeatTarget && target.seat.rigId.isNotEmpty) {
        _pollSeat();
        _seatPoll = Timer.periodic(seatPollEvery, (_) => _pollSeat());
      }
    });
  }

  Future<void> _pollSeat() async {
    final target = widget.target;
    final api = AppScope.clientOf(context);
    if (target is! SeatTarget || api == null) return;
    try {
      final polled = await pollSeat(api, target.seat, AppScope.read(context).active);
      if (!mounted || polled == null) return;
      final (fresh, _) = polled;
      setState(() => _seat = fresh);
    } catch (_) {/* keep the last known state */}
  }


  Future<void> _connect() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    setState(() => _error = null);
    try {
      // The one connect the tiles share (connectTerminal).
      final link = await connectTerminal(host, widget.target, _terminal,
          onInput: (data) => _input(data), alive: () => mounted, onError: (m) => setState(() => _error = m));
      if (link == null) return;
      _link = link;
      setState(() => _transport = link.transport);
      if (isDesktop) _focus.requestFocus();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// The clipboard's text to the program, as typed (bracketed when the program asked for it).
  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    _selection.clearSelection();
    if (text != null && text.isNotEmpty) _terminal.paste(text);
  }

  Future<void> _copy() async {
    final range = _selection.selection;
    if (range == null) return;
    await Clipboard.setData(ClipboardData(text: _terminal.buffer.getText(range)));
    _selection.clearSelection();
  }

  void _selectAll() => _selection.setSelection(
      _terminal.buffer.createAnchor(0, _terminal.buffer.height - _terminal.viewHeight),
      _terminal.buffer.createAnchor(_terminal.viewWidth, _terminal.buffer.height - 1));

  /// Applies the sticky modifiers from the key bar, then sends.
  void _input(String data) {
    final t = _transport;
    if (t == null) return;
    if (_mods.isNotEmpty) {
      data = applyModifiers(data, _mods);
      setState(() => _mods.removeWhere((m) => !_locked.contains(m)));
    }
    _send(data);
  }

  DateTime? _lastModTap;
  TermMod? _lastMod;

  /// One tap: on for the next key. Double tap: locked on. Tap again: off.
  void _toggleMod(TermMod m) {
    final now = DateTime.now();
    final double =
        _lastMod == m && _lastModTap != null && now.difference(_lastModTap!) < const Duration(milliseconds: 350);
    _lastMod = m;
    _lastModTap = now;
    setState(() {
      if (double) {
        _mods.add(m);
        _locked.add(m);
      } else if (_mods.contains(m)) {
        _mods.remove(m);
        _locked.remove(m);
      } else {
        _mods.add(m);
      }
    });
  }

  Route<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A project shell stays put; only a seat's terminal gets swapped out.
    if (widget.target is! SeatTarget) return;
    seatScreenRoutes.remove(_route);
    terminalRoutes.remove(_route);
    _route = ModalRoute.of(context);
    if (_route != null) {
      seatScreenRoutes.add(_route!);
      terminalRoutes.add(_route!);
    }
    topRoute.refresh();
  }

  @override
  void dispose() {
    seatScreenRoutes.remove(_route);
    terminalRoutes.remove(_route);
    if (needsYouAlerts.focusedSession ==
        (widget.target is SeatTarget ? (widget.target as SeatTarget).seat.sessionName : null)) {
      needsYouAlerts.focusedSession = null;
    }
    _seatPoll?.cancel();
    _scroll.dispose();
    _link?.close();
    _focus.dispose();
    _selection.dispose();
    super.dispose();
  }

  Duration? _lastDown;

  /// A double click (desktop only) on a rig agent's terminal goes to its rig's tiles, in its place (one client per agent). A loose agent has no rig, so it stays.
  void _down(PointerDownEvent e) {
    final target = widget.target;
    if (!isDesktop || target is! SeatTarget || target.seat.rigId.isEmpty || widget.loose != null) return;
    // The pointer's own timestamp, as in the tiles: a loaded machine can't stretch two quick presses apart.
    final double = _lastDown != null && e.timeStamp - _lastDown! < const Duration(milliseconds: 300);
    _lastDown = double ? null : e.timeStamp;
    if (!double) return;
    _openTiles(target);
  }

  Future<void> _openTiles(SeatTarget target) async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final rig = (await api.rigs()).firstWhere((r) => r.id == target.seat.rigId);
      final seats = await api.seats(rig.id);
      if (!mounted) return;
      final cwd = target.seat.cwd;
      final project = cwd == null ? rig.name : folderName(cwd);
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => TilesScreen(rig: rig, seats: seats, projectName: project)));
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  /// The seat's chat, in this screen's place (not a page over it): Back leaves the agent.
  void _toChat() {
    final target = widget.target;
    if (target is! SeatTarget) return;
    switchAgentView(
      context,
      (_) => ChatScreen(
          rigName: target.rigName, seat: _seat ?? target.seat, loose: widget.loose, rigs: widget.rigs, asChat: true),
      session: target.seat.sessionName,
    );
  }

  Future<void> _reconnect() async {
    await _link?.close();
    _link = null;
    if (mounted) setState(() => _transport = null);
    await _connect();
  }

  /// The ⋯: a rig seat gets the seat sheet, as in the chat, plus the terminal's own Reflow and Reconnect; a
  /// project shell or an agent outside a rig gets those and the chat.
  Future<void> _showMenu(bool claude, TerminalTransport? t) async {
    final target = widget.target;
    final extras = <(IconData, String, VoidCallback)>[(Icons.refresh_outlined, 'Reconnect', _reconnect)];
    if (target is SeatTarget && widget.loose == null && target.seat.nodeId != null && target.rigName != 'no rig') {
      await showSeatSheet(context, target.rigName, _seat ?? target.seat,
          fromTerminal: true,
          extraActions: extras,
          onChat: _toChat,
          onGone: () {
            if (mounted) Navigator.of(context).pop();
          });
      return;
    }
    final host = AppScope.read(context).active;
    if (target is ProjectShellTarget && host != null) {
      final shell = ProjectShell(projectShellSession(target.path), target.path);
      await showActionSheet(
        context,
        host.shellLabel(shell.name),
        [
          (Icons.height_outlined, 'Reflow', 'Fit the pane to this window again', _reflow),
          for (final (icon, label, run) in extras) (icon, label, null, run),
          (Icons.folder_outlined, 'Copy path', displayPath(target.path), () => _copyPath(target.path)),
          (Icons.edit_outlined, 'Rename…', 'Only shown in this app', () async {
            await renameShellLabel(context, host, shell);
            if (mounted) setState(() {});
          }),
        ],
        // The one Close shell, as in the sidebar and the project's Shells tab; the screen has nothing left to show after it.
        danger: [
          (
            'Close shell…',
            Icons.close,
            () async {
              if (await confirmCloseShell(context, host, shell) && mounted) Navigator.of(context).pop();
            }
          ),
        ],
      );
      return;
    }
    await showActionSheet(context, null, [
      for (final (icon, label, run) in extras) (icon, label, null, run),
    ]);
  }

  /// Tells tmux this window's size again (the pane keeps the size of the last window that attached).
  void _reflow() => _transport?.resize(_terminal.viewWidth, _terminal.viewHeight);

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) toast(context, 'Copied $path');
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = _transport;
    final target = widget.target;
    if (target is SeatTarget) showsInPanel(context, seatPanelKey(target.seat));
    final isSeat = target is SeatTarget;
    final claude = target is SeatTarget && target.seat.isClaude;
    final where = switch (target) {
      SeatTarget(:final rigName, :final seat) => [
          if (seat.cwd case final cwd?) folderName(cwd),
          if (rigName != 'no rig' || seat.cwd == null) rigName,
        ].join(' › '),
      ProjectShellTarget(:final path) => displayPath(path),
    };
    // On desktop the frame shows the seat's live state: orange when it needs you, green while it works.
    final status = isSeat ? Status.of((_seat ?? target.seat).state) : null;
    final edge = status?.edge(k);
    return Scaffold(
      backgroundColor: k.termBg,
      body: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: edge == null ? null : Border.all(color: edge, width: 2)),
        child: Column(children: [
        AgentHeader(
          seat: isSeat ? (_seat ?? target.seat) : null,
          title: switch (target) {
            SeatTarget(:final seat) => seat.logicalId,
            ProjectShellTarget(:final path) =>
              AppScope.of(context).active?.rigNames[projectShellSession(path)] ?? target.title,
          },
          subtitle: Text(where, style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          menuTooltip: 'Seat options',
          onMenu: () => _showMenu(claude, t),
          showing: isSeat ? AgentView.terminal : null,
          views: agentViews(isSeat ? (_seat ?? target.seat) : null),
          onSwitch: _toChat,
          extraActions: [if (isDesktop && isSeat) const AgentPanelsToggle()],
          // Only while not connected.
          bottom: t != null
              ? null
              : Text(_error == null ? 'connecting…' : 'not connected',
                  style: mono(context), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.all(8), action: 'Reconnect', onAction: _connect),
        Expanded(
          child: Stack(children: [
          Positioned.fill(
          child: PanelPreviewHost(
          seat: isDesktop && target is SeatTarget ? target.seat : null,
          focus: _focus,
          child: Builder(builder: (context) {
            const pad = 2.0;
            const size = 12.0;
            final style = terminalStyle(size);
            final line = size * style.height;
            final view = Listener(
              // Raw pointer events: the terminal's own gestures still handle taps and selection. A finger drags
              // tmux's history; a mouse drag selects text, so on a Mac the wheel and the trackpad scroll instead.
              onPointerDown: _down,
              // Not while a long press has selected text: that drag extends the selection.
              onPointerMove: (e) {
                if (_selection.selection == null) _scroll.onPointerMove(e, line);
              },
              onPointerSignal: (e) => _scroll.onPointerSignal(e, line),
              onPointerPanZoomUpdate: (e) => _scroll.onPanZoomUpdate(e, line),
              child: TerminalView(
                _terminal,
                controller: _selection,
                focusNode: _focus,
                autofocus: isDesktop,
                autoResize: true,
                theme: TerminalThemes.defaultTheme,
                backgroundOpacity: 0,
                textStyle: style,
                padding: const EdgeInsets.all(pad),
                // Not arrow keys: in tmux they'd walk the program's history, not scroll.
                simulateScroll: false,
                onTapUp: (d, cell) => openLinkOnModClick(_terminal, d, cell),
                // The phone keyboard sends no key for Backspace on an empty field: xterm keeps a placeholder to delete.
                deleteDetection: !isDesktop,
                // Plain ASCII keys, no suggestions or autocorrect.
                keyboardType: TextInputType.visiblePassword,
                onKeyEvent: shiftEnterNewline(_input),
              ),
            );
            return Stack(children: [Positioned.fill(child: view),
              // Scrolled back into tmux's history: the way back to the live output (typing does it too). In the child, so
              // it goes with the terminal when a dock preview covers it.
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
          ),
          // A long press selects a word (xterm); the menu is what to do with the selection.
          if (!isDesktop && _selection.selection != null)
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: k.ink,
                borderRadius: BorderRadius.circular(kRadius),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final (label, run) in [('Copy', _copy), ('Select all', _selectAll), ('Paste', _paste)])
                    TextButton(
                      onPressed: run,
                      style: TextButton.styleFrom(foregroundColor: k.onInk),
                      child: Text(label),
                    ),
                ]),
              ),
            ),
          ]),
        ),
        // A waiting agent is answered in the chat (or the Inbox), not here: this line says so and goes there.
        if (isSeat && status == Status.needsYou) NeedsYouStrip(onTap: _toChat),
        // Desktop has a real keyboard: no key area. Prompts are answered in chat and the Inbox, not here.
        if (!isDesktop) ...[
        if (target is SeatTarget) PanelsStrip(seat: target.seat),
        Container(
          color: k.fill,
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_keysOpen) TerminalKeyBar(mods: _mods, locked: _locked, onMod: _toggleMod, onKey: _input, onPaste: _paste),
              _collapsedKeys(k),
            ]),
          ),
        ),
        ],
      ]),
      ),
    );
  }
}

/// The keys a phone keyboard lacks that the always-there row (esc, tab, ctrl, ↑, ↓, Enter) does not carry, in one row that
/// scrolls: ← →, Alt and Shift (sticky: tap for the next key, double tap to lock), Paste, and the Ctrl and paging set.
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar(
      {super.key, required this.mods, required this.locked, required this.onMod, required this.onKey, required this.onPaste});
  final Set<TermMod> mods;
  final Set<TermMod> locked;
  final ValueChanged<TermMod> onMod;
  final void Function(String) onKey;
  final VoidCallback onPaste;

  static const _extra = <(String, String, String)>[
    ('⇧tab', '\x1b[Z', 'Shift Tab'),
    ('^C', '\x03', 'Control C'),
    ('^D', '\x04', 'Control D'),
    ('^R', '\x12', 'Control R'),
    ('pgup', '\x1b[5~', 'Page up'),
    ('pgdn', '\x1b[6~', 'Page down'),
    ('^Z', '\x1a', 'Control Z'),
    ('^L', '\x0c', 'Control L'),
    ('home', '\x1b[H', 'Home'),
    ('end', '\x1b[F', 'End'),
  ];

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    Widget key(String label, String spoken, VoidCallback onTap, {bool? on, bool lock = false}) {
      final button = SizedBox(
        height: 44,
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(40, 44),
            backgroundColor: on == true ? k.ink : k.surface,
            foregroundColor: on == true ? k.onInk : k.ink,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius),
              side: lock
                  ? BorderSide(color: k.added, width: 2)
                  : BorderSide(color: on == true ? k.ink : k.border),
            ),
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontFamily: fontMono, fontSize: 12)),
        ),
      );
      return Semantics(
        button: true,
        label: spoken + (lock ? ', locked' : ''),
        toggled: on,
        onTap: onTap,
        excludeSemantics: true,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: button),
      );
    }

    Widget mod(String label, String spoken, TermMod m) =>
        key(label, spoken, () => onMod(m), on: mods.contains(m), lock: locked.contains(m));

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          key('←', 'Left arrow', () => onKey('\x1b[D')),
          key('→', 'Right arrow', () => onKey('\x1b[C')),
          mod('alt', 'Alt', TermMod.alt),
          mod('⇧', 'Shift', TermMod.shift),
          key('paste', 'Paste', onPaste),
          for (final (label, seq, spoken) in _extra) key(label, spoken, () => onKey(seq)),
        ]),
      ),
    );
  }
}
