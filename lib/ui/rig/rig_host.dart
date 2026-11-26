import 'package:flutter/material.dart';

import '../../data/fleet.dart' show fleet;
import '../../data/host_store.dart' show isDesktop;
import '../../main.dart' show AppScope;
import '../../models.dart';
import '../rig_screen.dart' show RigScreen;
import '../tiles_screen.dart' show TilesScreen, enlargeRequest;

/// The two views of a rig on the Mac.
enum RigMode { tiles, rig }

/// A rig on the Mac: its page and its tiles in one screen, Rig details toggling between them. The tiles, once shown, stay
/// mounted (offstage, not ticking, taking no keys) while the page is up, so coming back shows the same live terminals with no
/// reconnect; the page is built when shown. Leaving the rig (Back) drops both. One screen means one route: Back leaves the rig
/// from either, and the sidebar's 'enlarge this agent' finds the tiles whichever is on show.
///
/// A phone, or a stopped rig (no tiles), is the plain [RigScreen]: use [rigRoute] to pick.
class RigHost extends StatefulWidget {
  const RigHost({super.key, required this.rig, required this.projectName, this.seats, this.initial = RigMode.tiles, this.enlarge, this.initialTab = 0, this.tab = 0});
  final Rig rig;
  final String projectName;

  /// The rig's seats if the caller has them (the tiles' first paint); else the host's feed has them.
  final List<Seat>? seats;
  final RigMode initial;

  /// Opens the tiles with this seat enlarged.
  final String? enlarge;

  /// The page's first tab and open tab (RigScreen's own).
  final int initialTab, tab;

  /// The nearest host above [context], or null on a screen that is not one.
  static RigHostState? maybeOf(BuildContext context) => context.findAncestorStateOfType<RigHostState>();

  @override
  State<RigHost> createState() => RigHostState();
}

class RigHostState extends State<RigHost> {
  late RigMode _mode = widget.initial;
  late bool _tilesBuilt = widget.initial == RigMode.tiles;
  late String? _enlarge = widget.enlarge;

  RigMode get mode => _mode;

  /// Rig details: the page when the tiles are up, the tiles when the page is.
  void toggle() => setState(() {
        _mode = _mode == RigMode.rig ? RigMode.tiles : RigMode.rig;
        if (_mode == RigMode.tiles) _tilesBuilt = true;
      });

  /// The rigs whose host is mounted (on any route): a chat over it sends its agent's Terminal to the tile.
  static final _live = <String, RigHostState>{};
  static bool isLive(String rigId) => _live.containsKey(rigId);

  @override
  void initState() {
    super.initState();
    _live[widget.rig.id] = this;
    enlargeRequest.addListener(_onEnlarge);
  }

  @override
  void dispose() {
    if (identical(_live[widget.rig.id], this)) _live.remove(widget.rig.id);
    enlargeRequest.removeListener(_onEnlarge);
    super.dispose();
  }

  /// An agent opened for this rig (the sidebar, the page's own list) opens in the tiles, enlarged: the tile's client is the
  /// agent's only one. From the page that means going to the tiles first.
  void _onEnlarge() {
    final r = enlargeRequest.value;
    if (r == null || r.rigId != widget.rig.id || _mode == RigMode.tiles) return;
    final built = _tilesBuilt;
    setState(() {
      _mode = RigMode.tiles;
      _tilesBuilt = true;
      if (!built) _enlarge = r.seat;
    });
    // Tiles not built yet take it as their first state; built ones take the request themselves.
    if (!built) enlargeRequest.value = null;
  }

  List<Seat> _seats(BuildContext context) {
    if (widget.seats != null && widget.seats!.isNotEmpty) return widget.seats!;
    final host = AppScope.of(context).active;
    final fromFeed = host == null ? null : fleet.feedFor(host).rigs.where((r) => r.rig.id == widget.rig.id).firstOrNull;
    return fromFeed?.seats ?? const [];
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _mode == RigMode.tiles;
    return Stack(children: [
      if (_tilesBuilt)
        Positioned.fill(
          key: const ValueKey('tiles'),
          child: Offstage(
            offstage: !tiles,
            child: ExcludeFocus(
              excluding: !tiles,
              child: TickerMode(
                enabled: tiles,
                child: TilesScreen(rig: widget.rig, seats: _seats(context), projectName: widget.projectName, enlarge: _enlarge),
              ),
            ),
          ),
        ),
      if (!tiles)
        Positioned.fill(key: const ValueKey('page'), child: RigScreen(rig: widget.rig, projectName: widget.projectName, initialTab: widget.initialTab, tab: widget.tab)),
    ]);
  }
}

/// A rig's screen: on the Mac a running rig is a [RigHost] (page and tiles), otherwise the plain [RigScreen].
Widget rigRoute(Rig rig, String projectName,
        {List<Seat>? seats, RigMode mode = RigMode.rig, String? enlarge, int initialTab = 0, int tab = 0, Key? key}) =>
    isDesktop && rig.status != 'stopped'
        ? RigHost(
            key: key, rig: rig, projectName: projectName, seats: seats, initial: mode, enlarge: enlarge, initialTab: initialTab, tab: tab)
        : RigScreen(key: key, rig: rig, projectName: projectName, initialTab: initialTab, tab: tab);
