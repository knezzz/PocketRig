import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, LogicalKeyboardKey;

import 'action_rows.dart';
import 'kit.dart' show outlinedRed;
import 'theme.dart';

/// Between two groups of a ⋯ list. The desktop popup draws a separator; the phone sheet leaves it out.
const ActionRow menuBreak = (Icons.horizontal_rule, '', null, null);

bool isMenuBreak(ActionRow r) => r.$2.isEmpty;

Offset _pointer = Offset.zero;
bool _tracking = false;

/// Where the mouse last went down: a menu opened from a click or a right click starts there. Caller code stays
/// the same for a ⋯ button, a row's right click and a long press.
void _trackPointer() {
  if (_tracking) return;
  _tracking = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute((e) {
    if (e is PointerDownEvent) _pointer = e.position;
  });
}

/// The Mac's ⋯ and right-click menu: a compact popup at the pointer (or at [at]), 28dp rows, an icon, no subtitles, a
/// separator between groups, the destructive actions red and last. Hover, ↑ ↓, Return and Escape are MenuAnchor's. The
/// chosen action runs as the menu closes. The phone shows [showActionSheet] with the same rows.
Future<void> showDesktopMenu(BuildContext context, ActionRows rows, {Offset? at}) {
  _trackPointer();
  final done = Completer<void>();
  final start = at ?? _pointer;
  late OverlayEntry entry;
  entry = OverlayEntry(
      builder: (_) => _MenuHost(
          rows: rows,
          at: start,
          onClosed: () {
            entry.remove();
            done.complete();
          }));
  Overlay.of(context, rootOverlay: true).insert(entry);
  return done.future;
}

class _MenuHost extends StatefulWidget {
  const _MenuHost({required this.rows, required this.at, required this.onClosed});
  final ActionRows rows;
  final Offset at;
  final VoidCallback onClosed;

  @override
  State<_MenuHost> createState() => _MenuHostState();
}

class _MenuHostState extends State<_MenuHost> {
  final _controller = MenuController();
  final _focus = FocusNode(debugLabel: 'desktop menu');
  // The enabled rows' focus, in order: a first ↓ or ↑ lands on the first or last one, and the menu takes over from there.
  final _nodes = <FocusNode>[];
  var _closed = false;

  @override
  void dispose() {
    _focus.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _controller.close();
      return KeyEventResult.handled;
    }
    if (_nodes.isNotEmpty && (e.logicalKey == LogicalKeyboardKey.arrowDown || e.logicalKey == LogicalKeyboardKey.arrowUp)) {
      (e.logicalKey == LogicalKeyboardKey.arrowDown ? _nodes.first : _nodes.last).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.open(position: widget.at);
      // The button that opened it holds the focus: take it, so Escape and the arrows reach the menu.
      _focus.requestFocus();
    });
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    // After the frame: the overlay entry is not removed while MenuAnchor is still closing its own.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onClosed());
  }

  Widget _item(Tokens k, ActionRow r, {bool danger = false}) {
    final (icon, label, _, run) = r;
    FocusNode? node;
    if (run != null) _nodes.add(node = FocusNode());
    final fg = danger ? outlinedRed(k) : k.ink;
    return MenuItemButton(
      focusNode: node,
      onPressed: run,
      leadingIcon: Icon(icon, size: 16),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(212, 28)),
        maximumSize: const WidgetStatePropertyAll(Size(420, 28)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: fontSans, fontSize: 13, fontWeight: FontWeight.w400)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(3))),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? k.muted : fg),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? k.muted : (danger ? fg : k.muted)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? k.fill : Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    for (final n in _nodes) {
      n.dispose();
    }
    _nodes.clear();
    final items = [for (final r in widget.rows.items) r];
    Widget sep() => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Divider(height: 1, thickness: 1, color: k.divider));
    final children = <Widget>[];
    var gap = false;
    for (final r in items) {
      if (isMenuBreak(r)) {
        gap = children.isNotEmpty;
        continue;
      }
      if (gap) children.add(sep());
      gap = false;
      children.add(_item(k, r));
    }
    if (widget.rows.danger.isNotEmpty) {
      if (children.isNotEmpty) children.add(sep());
      for (final (label, icon, run) in widget.rows.danger) {
        children.add(_item(k, (icon, label, null, run), danger: true));
      }
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: MenuAnchor(
      controller: _controller,
      onClose: _close,
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(k.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: const WidgetStatePropertyAll(Colors.black54),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        minimumSize: const WidgetStatePropertyAll(Size(220, 0)),
        side: WidgetStatePropertyAll(BorderSide(color: k.border)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius))),
      ),
      menuChildren: children,
      builder: (_, __, ___) => const SizedBox.expand(),
    ));
  }
}
