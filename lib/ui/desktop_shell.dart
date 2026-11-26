import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/agent_jobs.dart' show AgentJob;
import 'app_icon.dart';
import '../data/fleet.dart';
import '../data/home_order.dart';
import '../data/host_store.dart' show isDesktop;
import '../data/ux_log.dart' show uxRoutes;
import 'needs_you_banner.dart' show inboxRequests;
import '../main.dart';
import '../models.dart';
import 'common.dart' show ago, needsYouCount;
import 'progress_bar.dart' show ContextBar;
import 'command_palette.dart' show paletteCommands, showCommandPalette;
import 'action_rows.dart' show showActionRows;
import 'host_actions.dart' show hostActionRows;
import 'hosts/host_editor.dart' show HostEditor;
import 'hosts_screen.dart' show HostsScreen;
import 'common.dart' show useHost;
import 'project_actions.dart' show openShell, showProjectActions, showShellActions;
import 'project_screen.dart';
import 'chat_screen.dart' show opensAsChat, seatScreen;
import '../data/projects.dart' show groupByWorktree;
import 'kit.dart' show HoverBuilder, NavRow, ShellMenu, panelRouteName, navFillInset, navMouse, navSideInset, navSlotW, navIconGap, navTrailW, navRowTop, navNameLineH, navSecondLineH;
import 'loose_agent_screen.dart' show openLooseAgent, showLooseActions;
import 'terminal_screen.dart' show TerminalScreen;
import '../terminal/transport.dart' show SeatTarget;
import 'rig/rig_actions.dart' show showRigActions;
import 'rig/seat_sheet.dart' show showSeatSheet;
import 'project_tally.dart' show SeatTally, folderColor, looseActive, rigIconColor, looseRecent, looseState;
import 'recent_screen.dart';
import 'new_sheet.dart' show showNew;
import 'folder_browser.dart' show chooseFolder;
import 'rigs_home.dart';
import 'shells_screen.dart';
import 'host_color.dart';
import 'status_shape.dart';
import 'subagent_open.dart';
import 'theme.dart';
import 'worktree_chip.dart';
import '../data/usage_rings.dart' show usageNow;
import 'usage_strip.dart' show HostUsageBar, HostUsageLine, contextColor, contextWeight;
import 'rig_screen.dart' show RigScreen;
import 'tiles_screen.dart';

/// Narrower than this, the desktop window uses the phone layout.
const desktopPanesMinWidth = 1000.0;

/// The detail pane of a wide desktop window. Screens open seats, specs and
/// worktrees there through [detailNavigator].
class DetailPane extends InheritedWidget {
  const DetailPane({super.key, required this.nav, required super.child});
  final GlobalKey<NavigatorState> nav;

  @override
  bool updateShouldNotify(DetailPane old) => nav != old.nav;
}

/// Where a list opens what was tapped: the detail pane when the desktop
/// shows one (cleared down to whatever still has unsaved edits), else the
/// list's own navigator.
NavigatorState detailNavigator(BuildContext context) {
  final own = Navigator.of(context);
  final pane = context.getInheritedWidgetOfExactType<DetailPane>()?.nav.currentState;
  if (pane == null || identical(pane, own)) return own;
  return _cleared(pane);
}

NavigatorState _cleared(NavigatorState pane) =>
    pane..popUntil((r) => r.isFirst || r.popDisposition == RoutePopDisposition.doNotPop);

GlobalKey<NavigatorState>? _shown;

/// The phone's content panel history: what the drawer or a screen opened goes on a stack, and Back pops it.
_PanelHistory? _panelHistory;

/// A rig was deleted: its entries in the phone's panel history go, so Back never lands on a dead page.
void dropPanelRoutes(String rigId) {
  final h = _panelHistory;
  if (h == null) return;
  for (final r in [...h.routes]) {
    if (r != h.top && !r.isFirst && _inRig(r.settings.name ?? '', rigId)) h.nav?.removeRoute(r);
  }
}

/// What the content panel shows, for the sidebar to highlight: `project:<path>`, `rig:<rig id>` or
/// `seat:<rig id>/<seat>` (a loose agent's rig id is empty). Null for anything else.
final panelShows = ValueNotifier<String?>(null);

/// Called from a screen's build: while it's the top screen of the content panel, the sidebar highlights [key].
/// Depends on the route, so a screen uncovered by a pop reports itself again.
void showsInPanel(BuildContext context, String key) {
  final route = ModalRoute.of(context);
  final pane = context.getInheritedWidgetOfExactType<DetailPane>()?.nav.currentState;
  if (route == null || !route.isCurrent || pane == null || route.navigator != pane) return;
  if (panelShows.value != key) WidgetsBinding.instance.addPostFrameCallback((_) => panelShows.value = key);
}

/// [panel] shows rig [rigId] or one of its agents.
bool _inRig(String panel, String rigId) => panel == 'rig:$rigId' || panel.startsWith('seat:$rigId/');

/// What a worktree's page reports to [showsInPanel], so its row in the sidebar is selected.
String worktreePanelKey(String project, String name) => 'worktree:$project/$name';

String seatPanelKey(Seat s) => 'seat:${s.rigId}/${s.logicalId}';

/// The detail pane while a wide desktop window shows one, cleared for a new
/// screen; null otherwise. For openers outside any list (alerts, the banner).
NavigatorState? shownDetailPane() => switch (_shown?.currentState) { final n? => _cleared(n), null => null };

/// The one shell, on desktop and phone: the sidebar tree (permanent when wide, else a drawer) beside the content
/// panel, which opens on the Inbox, or on Settings until a host exists.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Tests of the sidebar and the Inbox start on the Inbox, as the app did before the Rigs home became its start screen.
  @visibleForTesting
  static bool debugStartOnInbox = false;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _detail = GlobalKey<NavigatorState>();
  final _scaffold = GlobalKey<ScaffoldState>();
  String? _project;

  /// The Inbox, or the hosts settings, fill the content panel instead of a project.
  bool _inbox = true;
  bool _settings = false;

  /// The Rigs home fills the panel.
  bool _home = false;

  /// The sidebar folded away, so the content panel gets the whole width.
  bool _collapsed = false;
  void _toggleCollapsed() => setState(() => _collapsed = !_collapsed);

  /// The sidebar's width while its border is dragged; the store keeps it from the drag's end.
  double? _dragWidth;
  static const _sidebarMin = 200.0, _sidebarMax = 480.0;

  /// At most 480, and never so wide the panel drops under 560 in the smallest desktop window.
  double _clampWidth(double w, double window) => w.clamp(_sidebarMin, (window - 560).clamp(_sidebarMin, _sidebarMax));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First run: the panel opens on Settings (its initial route), until a host exists.
    if (!_started) {
      _started = true;
      _settings = AppScope.of(context).active == null;
      _home = !_settings && !AppShell.debugStartOnInbox;
      _inbox = !_settings && AppShell.debugStartOnInbox;
    }
  }

  bool _started = false;

  late final _history = _PanelHistory(() {
    // The drawer's edge drag steps aside while Back has somewhere to go: the edge swipe goes back, the lip opens the drawer.
    if (mounted) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
  });

  @override
  void initState() {
    super.initState();
    _panelHistory = _history;
    _shown = _detail;
    inboxRequests.addListener(_openInbox);
    subagentRequests.addListener(_openSubagent);
  }

  @override
  void dispose() {
    if (_shown == _detail) _shown = null;
    if (_panelHistory == _history) _panelHistory = null;
    inboxRequests.removeListener(_openInbox);
    subagentRequests.removeListener(_openSubagent);
    super.dispose();
  }

  /// Puts [screen] at the root of the content panel, in place of what was there. A route holding unsaved edits stays:
  /// the screen goes on top of it instead.
  void _show(Widget screen, {String? id}) {
    // The panel's observer sees a push, not this replace, so the drawer closes here.
    _scaffold.currentState?.closeDrawer();
    if (!isDesktop) {
      // The phone keeps a history: Back returns to the screen before, and the screen already on top isn't pushed again.
      if (id != null && _history.top?.settings.name == id) return;
      _detail.currentState!.push(MaterialPageRoute<void>(settings: RouteSettings(name: id), builder: (_) => screen));
      return;
    }
    final nav = _cleared(_detail.currentState!);
    // Named, so its header shows no back arrow: a page the sidebar opened is a panel root, not a step in a stack.
    final route = MaterialPageRoute<void>(settings: const RouteSettings(name: panelRouteName), builder: (_) => screen);
    if (nav.canPop()) {
      nav.push(route);
    } else {
      nav.pushReplacement(route);
    }
  }

  /// A sidebar subagent row: its log, as a chat, in the content panel (the screen the chat's Subagents list opens).
  void _openSubagent() {
    final r = lastSubagentRequest;
    if (r == null) return;
    useHost(context, r.host);
    _show(subagentScreen(r.parent, r.sub), id: 'sub:${r.sub.agentId}');
  }

  /// The command palette: the shown object's actions, each host's, and where to go. Desktop only.
  void _openPalette() {
    if (!isDesktop) return;
    // The commands are built and run with the content pane's context: screens they open land in the panel (the
    // sidebar stays), as from a row's ⋯, not on the root navigator.
    final pane = _detail.currentContext ?? context;
    showCommandPalette(
        context,
        paletteCommands(pane,
            onInbox: _openInbox,
            onSettings: _openSettings,
            onProject: _pick,
            onRig: (host, project, r) => _openRig(host, project.path, project.name, r)));
  }

  /// A project of [host]: the screens below read the active host, so it becomes the active one.
  void _pick(Host host, String project) {
    useHost(context, host);
    uxRoutes.tab('Projects');
    setState(() {
      _project = project;
      _inbox = false;
      _home = false;
      _settings = false;
    });
    _show(ProjectScreen(path: project), id: 'project:$project');
  }

  /// A running rig: its tiles fill the content panel, whatever was showing, another rig's tiles included. [enlarge]
  /// is an agent of it, enlarged as by a double click; tiles of that rig already on top just enlarge it.
  void _openRig(Host host, String project, String projectName, RigWithSeats r, {String? enlarge}) {
    useHost(context, host);
    setState(() {
      _project = project;
      _inbox = false;
      _home = false;
      _settings = false;
    });
    if (!isDesktop) {
      final home = rigHome(r, projectName, enlarge: enlarge);
      _show(home, id: home is RigScreen ? 'rig:${r.rig.id}' : 'seat:${r.rig.id}/$enlarge');
      return;
    }
    // The Mac's first screen for a rig is rigHome's too (the tiles of a running rig, the page of a stopped one).
    if (enlarge != null && r.rig.status != 'stopped' && tilesEnlarge(r.rig.id, enlarge)) return;
    final home = rigHome(r, projectName, enlarge: enlarge, key: ValueKey('${host.id}:${r.rig.id}'));
    _show(home, id: home is RigScreen ? 'rig:${r.rig.id}' : null);
  }

  void _openSettings() {
    setState(() {
      _settings = true;
      _inbox = false;
      _home = false;
      _project = null;
    });
    panelShows.value = null;
    uxRoutes.tab('Settings');
    _show(const HostsScreen(), id: 'settings');
  }

  /// The Rigs home: every host's projects, their rigs and the agents running outside a rig, as cards.
  void _openHome() {
    setState(() {
      _home = true;
      _inbox = false;
      _settings = false;
      _project = null;
    });
    panelShows.value = null;
    uxRoutes.tab('Rigs');
    if (!isDesktop) {
      // The Rigs home is the bottom of the phone's history.
      _detail.currentState!.popUntil((r) => r.isFirst);
      _scaffold.currentState?.closeDrawer();
      return;
    }
    _show(const RigsHome());
  }

  void _openInbox() {
    setState(() {
      _inbox = true;
      _home = false;
      _settings = false;
      _project = null;
    });
    panelShows.value = null;
    uxRoutes.tab('Inbox');
    _show(const RecentScreen(), id: 'inbox');
  }

  /// Adds a folder to the project list (a pin, as on the phone) and opens it.
  Future<void> _addFolder(Host host) async {
    // This Mac: the system picker; another host: the in-app browser over SSH.
    final path = await chooseFolder(context, host);
    if (path == null || !mounted) return;
    await AppScope.read(context).pinFolder(host, path);
    if (mounted) _pick(host, path);
  }

  /// A folder was unpinned from its list: if it is the open project, back to the Rigs home.
  void _unpinned(String path) {
    if (mounted && _project == path) _openHome();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    // First run: nothing to show until a host exists.
    if (store.active == null && !_settings) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _openSettings() : null);
    return LayoutBuilder(builder: (context, box) => _build(context, box.maxWidth >= desktopPanesMinWidth, box.maxWidth));
  }

  Widget _build(BuildContext context, bool wide, double window) {
    final k = Tokens.of(context);
    final store = AppScope.of(context);
    final sideW = _clampWidth(_dragWidth ?? store.sidebarWidth, window);
    final sidebar = _Sidebar(
      hosts: store.hosts,
      active: store.active?.id,
      project: _project,
      inbox: _inbox,
      home: _home,
      settings: _settings,
      onHome: _openHome,
      onSearch: isDesktop ? _openPalette : null,
      onInbox: _openInbox,
      onSettings: _openSettings,
      onPick: _pick,
      onRig: _openRig,
      onAdd: _addFolder,
      onCollapse: wide ? _toggleCollapsed : null,
    );
    final panel = NavigatorPopHandler(
      onPopWithResult: (_) => _detail.currentState?.maybePop(),
      child: Navigator(
        key: _detail,
        // A pick closes the drawer, whichever way it got there.
        observers: [_DrawerCloser(() => _scaffold.currentState?.closeDrawer()), _history],
        onGenerateRoute: (_) => PageRouteBuilder(
            settings: RouteSettings(
                name: AppScope.of(context).active == null ? 'settings' : (AppShell.debugStartOnInbox ? 'inbox' : 'rigs')),
            pageBuilder: (c, a, b) => AppScope.of(c).active == null
                ? const HostsScreen()
                : AppShell.debugStartOnInbox
                    ? const RecentScreen()
                    : const RigsHome()),
      ),
    );
    return DetailPane(
      nav: _detail,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.backslash, meta: true): _toggleCollapsed,
          // ⌘⇧P (Ctrl+Shift+P off the Mac): the command palette.
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _openPalette,
          const SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true): _openPalette,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): _openPalette,
        },
        child: Scaffold(
          key: _scaffold,
          drawer: wide ? null : Drawer(shape: const RoundedRectangleBorder(), child: sidebar),
          drawerEnableOpenDragGesture: !_history.canGoBack,
          body: Stack(children: [
            Row(children: [
            if (wide && !_collapsed) ...[
              SizedBox(key: const ValueKey('sidebar'), width: sideW, child: sidebar),
              VerticalDivider(width: 1, color: k.border),
            ],
            Expanded(
              // The menu button for the panel's root screen: opens the drawer, or unfolds the sidebar.
              child: wide && !_collapsed
                  ? panel
                  : ShellMenu(
                      open: wide ? _toggleCollapsed : () => _scaffold.currentState?.openDrawer(), child: panel),
            ),
            ]),
            if (!wide) _DrawerLip(open: () => _scaffold.currentState?.openDrawer()),
            // The border, grabbed over 7dp (3 each side of the line): drag to resize, kept when the drag ends.
            if (wide && !_collapsed)
              Positioned(
                left: sideW - 3,
                top: 0,
                bottom: 0,
                width: 7,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const ValueKey('sidebar-resize'),
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (d) => setState(() => _dragWidth = _clampWidth(sideW + d.delta.dx, window)),
                    onHorizontalDragEnd: (_) {
                      if (_dragWidth != null) store.setSidebarWidth(_dragWidth!);
                    },
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Keeps the phone panel's routes, to know the top one, whether Back has somewhere to go, and what to drop.
class _PanelHistory extends NavigatorObserver {
  _PanelHistory(this.changed);
  final VoidCallback changed;
  final routes = <Route<dynamic>>[];
  Route<dynamic>? get top => routes.lastOrNull;
  bool get canGoBack => routes.length > 1;
  NavigatorState? get nav => navigator;
  void _set(void Function() f) {
    f();
    changed();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _set(() => routes.add(route));
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _set(() => routes.remove(route));
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _set(() => routes.remove(route));
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _set(() {
        final i = routes.indexOf(oldRoute!);
        if (i < 0 || newRoute == null) return;
        routes[i] = newRoute;
      });
}

/// A small mark on the phone's left edge, a drag or a tap on which opens the drawer; the edge swipe elsewhere goes back.
class _DrawerLip extends StatelessWidget {
  const _DrawerLip({required this.open});
  final VoidCallback open;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    var dragged = 0.0;
    return Positioned.fill(
      child: Align(
        alignment: const Alignment(-1, -0.2),
        child: SizedBox(
          key: const ValueKey('drawer-lip'),
          width: 44,
          height: 64,
          child: Semantics(
        button: true,
        label: 'Open menu',
        onTap: open,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            onHorizontalDragStart: (_) => dragged = 0,
            onHorizontalDragUpdate: (d) {
              dragged += d.delta.dx;
              if (dragged > 12) {
                dragged = double.negativeInfinity;
                open();
              }
            },
            child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                    width: 6,
                    height: 52,
                    margin: const EdgeInsets.only(left: 2),
                    decoration: BoxDecoration(color: k.faint, borderRadius: const BorderRadius.horizontal(right: Radius.circular(3))))),
          ),
        ),
          ),
        ),
      ),
    );
  }
}

class _DrawerCloser extends NavigatorObserver {
  _DrawerCloser(this.close);
  final VoidCallback close;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => close();
}

/// Tree geometry. A row is [12dp per level][16 fold slot][8][16 icon slot][18][label … trailing]; the guides run down the
/// middle of the fold slot of each ancestor.
const _slotW = navSlotW, _agentGap = 18.0;

/// Indent per level and the side inset of a row: roomier for a finger than for a mouse.
double get _indent => _mouse() ? 12 : 14;
double get _sideInset => navSideInset();

/// Rows are 48dp for a finger, 28 with a mouse. A desktop starts dense, before any pointer event. A [compact] row
/// (a subagent: read-only) is about half that.
bool _mouse() => navMouse();
double _rowHeight({bool compact = false}) => compact ? (_mouse() ? 18 : 28) : (_mouse() ? 32 : 48);

/// The four levels of the tree. Their look is set here and nowhere else.
enum _Level { host, project, rig, agent }

TextStyle _labelStyle(BuildContext context, _Level? level, {Color? color, bool strong = false}) {
  final k = Tokens.of(context);
  return switch (level) {
    // Section label: uppercase mono, in the host's color.
    _Level.host => mono(context, size: 11, weight: FontWeight.w700, color: color ?? k.ink).copyWith(letterSpacing: 0.8),
    // Bold ink.
    _Level.project => TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w800 : FontWeight.w700, color: k.ink),
    // Normal weight, a lighter grey.
    _Level.rig => TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w600 : FontWeight.w400, color: strong ? k.ink : k.muted),
    _ => TextStyle(
        fontSize: 13, fontWeight: strong ? FontWeight.w600 : FontWeight.w400, color: color ?? k.ink),
  };
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.hosts,
    required this.active,
    required this.project,
    required this.inbox,
    required this.home,
    required this.settings,
    required this.onHome,
    this.onSearch,
    required this.onInbox,
    required this.onSettings,
    required this.onPick,
    required this.onRig,
    required this.onAdd,
    this.onCollapse,
  });
  final List<Host> hosts;
  final String? active;
  final String? project;
  final bool inbox;
  final bool home;
  final bool settings;
  final VoidCallback onHome;

  /// Opens the command palette (the Mac); null where there is none.
  final VoidCallback? onSearch;
  final VoidCallback onInbox;
  final VoidCallback onSettings;
  final void Function(Host, String) onPick;
  final void Function(Host, String project, String projectName, RigWithSeats rig, {String? enlarge}) onRig;
  final void Function(Host) onAdd;

  /// The header's fold button (desktop); null where the sidebar is a drawer.
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    // Drops the feeds of removed hosts; each section listens to its own feed, so none restarts on a rebuild.
    fleet.sync(hosts);
    return ColoredBox(
      color: k.headerFill,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: RefreshIndicator(
          onRefresh: () => Future.wait([for (final h in hosts) fleet.feedFor(h).refresh(scan: true)]),
          child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(0, 4, 0, 14), children: [
            // Search (the command palette; the Mac) and the New sheet, above the Rigs and Inbox rows.
            Padding(
              padding: EdgeInsets.fromLTRB(_sideInset, 4, _sideInset + navFillInset, 6),
              child: Row(children: [
                if (onSearch != null)
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: 'Search',
                      excludeSemantics: true,
                      onTap: onSearch,
                      child: Material(
                        color: k.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
                        child: InkWell(
                          onTap: onSearch,
                          child: Padding(
                            // The same grid as the rows below: fill inset 6, an icon in the 16 slot, the 9 gap. 32 tall (the block 42 with its 4 and 6).
                            padding: const EdgeInsets.symmetric(horizontal: navFillInset),
                            child: SizedBox(height: 32, child: Row(children: [
                              SizedBox(width: navSlotW, child: Center(child: Icon(Icons.search, size: 16, color: k.muted))),
                              const SizedBox(width: navIconGap),
                              Expanded(child: Text('Search', style: TextStyle(fontSize: 13, color: k.muted))),
                              Text('⌘K', style: mono(context, size: 11, color: k.faint)),
                            ])),
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                // New agent, shell or rig: the sheet with its location and worktree.
                IconButton.outlined(
                    tooltip: 'New…',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => showNew(context),
                    icon: const Icon(Icons.add, size: 18)),
                if (onCollapse != null)
                  IconButton(
                    tooltip: 'Hide sidebar (⌘\\)',
                    visualDensity: VisualDensity.standard,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tightFor(width: navTrailW(), height: 32),
                    style: IconButton.styleFrom(minimumSize: Size(navTrailW(), 32), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: onCollapse,
                    icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
                  ),
              ]),
            ),
            NavRow(
              leading: const AppIcon(AppIconKind.rig, size: 16),
              label: 'Rigs',
              selected: home,
              onTap: onHome,
            ),
            ValueListenableBuilder<int>(
              valueListenable: needsYouCount,
              builder: (context, needs, _) => NavRow(
                leading: const Icon(Icons.inbox_outlined, size: 16),
                label: 'Inbox',
                count: needs,
                selected: inbox,
                onTap: onInbox,
              ),
            ),
            // What the content panel shows is highlighted, on the active host (paths repeat across hosts).
            // Live hosts first, offline ones after them (each group in the host list's order), looked at on every change.
            ListenableBuilder(
              listenable: Listenable.merge([for (final h in hosts) fleet.feedFor(h)]),
              builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final h in liveHostsFirst(hosts))
                  _HostSection(
                    host: h,
                    several: hosts.length > 1,
                    onSettings: onSettings,
                    active: h.id == active,
                    onPick: (path) => onPick(h, path),
                    onRig: (path, name, r, {enlarge}) => onRig(h, path, name, r, enlarge: enlarge),
                    onAdd: () => onAdd(h),
                  ),
              ]),
            ),
          ]),
        )),
        // The footer: the hosts at a glance; the whole row opens Hosts and settings.
        Divider(height: 1, color: k.border),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Tooltip(
            message: 'Hosts and settings',
            child: NavRow(
              leading: Icon(Icons.desktop_windows_outlined, size: 16, color: k.muted),
              label: hosts.length == 1 ? '1 host' : '${hosts.length} hosts',
              body: Row(children: [
                // The swatches clip when there are many; the count after them always shows.
                Flexible(
                  child: SizedBox(
                    height: 10,
                    child: Wrap(clipBehavior: Clip.hardEdge, spacing: 4, children: [
                      for (final h in hosts) Container(width: 10, height: 10, decoration: BoxDecoration(color: hostTextColor(h, k), borderRadius: BorderRadius.circular(2))),
                    ]),
                  ),
                ),
                const SizedBox(width: 8),
                Text(hosts.length == 1 ? '1 host' : '${hosts.length} hosts', maxLines: 1, style: mono(context, size: 12, color: k.muted)),
              ]),
              selected: settings,
              onTap: onSettings,
              trailing: Icon(Icons.more_horiz, size: 16, color: k.muted),
            ),
          ),
        ),
        ]),
      ),
    );
  }
}

/// How many agents on [host] need you, in the accent, beside its name; nothing at 0.
class _HostNeeds extends StatelessWidget {
  const _HostNeeds(this.host);
  final Host host;

  @override
  Widget build(BuildContext context) {
    final feed = fleet.feedFor(host);
    // Structured questions waiting on the person count with the asking agents, as in the Inbox's number.
    final n = SeatTally(host, [for (final r in feed.rigs) r], [for (final p in feed.projects) ...p.loose], wholeHost: true).needs + feed.coreAsks;
    if (n == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Semantics(
        label: '$n need you',
        excludeSemantics: true,
        child: Text('$n', style: mono(context, size: 12, color: Tokens.of(context).accent, weight: FontWeight.w700)),
      ),
    );
  }
}

/// A host's list: Edit host (its editor, in the content panel) and Rescan.
void _hostMenu(BuildContext context, Host host) {
  final rows = hostActionRows(host);
  showActionRows(context, host.name, (
    items: [
      (Icons.edit_outlined, 'Edit host', null, () => detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => HostEditor(host: host)))),
      ...rows.items,
    ],
    danger: rows.danger,
  ));
}

/// One host: its name and state, then its projects. An unreachable host says so here and leaves the rest alone.
class _HostSection extends StatelessWidget {
  const _HostSection({
    required this.host,
    required this.several,
    required this.onSettings,
    required this.active,
    required this.onPick,
    required this.onRig,
    required this.onAdd,
  });
  final Host host;

  /// More than one host: a tap on the header folds it; with one, it opens Hosts and settings, as the footer does.
  final bool several;
  final VoidCallback onSettings;
  final bool active;
  final void Function(String) onPick;
  final void Function(String project, String projectName, RigWithSeats rig, {String? enlarge}) onRig;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final feed = fleet.feedFor(host);
    // The host's own color reads on the dark ground only when lifted toward the ink.
    final hc = hostTextColor(host, k);
    return ListenableBuilder(
      // The fleet too: a rig and a project fold through it.
      listenable: Listenable.merge([feed, fleet, panelShows]),
      builder: (context, _) {
        final projects = feed.projects;
        final panel = active ? panelShows.value : null;
        final folded = fleet.hostFolded(host.id);
        final hasUsage = HostUsageBar.claudeReadings(host, HostUsageBar.clock()).isNotEmpty;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 12),
          // The name; the address only when it can't be reached.
          // A section header: a tap folds the host (with several; with one it opens Hosts and settings), the long press and right click open its list (Edit host, Rescan).
          GestureDetector(
            onLongPress: () => _hostMenu(context, host),
            onSecondaryTap: () => _hostMenu(context, host),
            child: Semantics(
              hint: several ? (folded ? 'Unfold ${host.name}' : 'Fold ${host.name}') : 'Hosts and settings',
              child: NavRow(
                leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: hc, borderRadius: BorderRadius.circular(2))),
                leadingWidth: 10,
                label: host.name.toUpperCase(),
                // The name and, beside it, how many agents on the host need you (the accent; nothing at 0).
                body: Row(children: [
                  Flexible(child: Text(host.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle(context, _Level.host, color: hc))),
                  if (feed.error == null) _HostNeeds(host),
                ]),
                // The name; the address only when it can't be reached.
                meta: feed.error != null ? 'offline · ${host.address}:${host.daemonPort}' : null,
                onTap: several ? () => fleet.toggleHost(host.id) : onSettings,
                // Folded: how many agents are active on the host (needs you + working), ending where every count does; the usage
                // rows go with the projects and come back when it unfolds.
                endLabel: feed.error == null && folded ? HostActiveCount(host, padded: false) : null,
                // Unreachable: a small retry (an icon, so the header still fits the narrowest sidebar), in the trailing column.
                trailing: feed.error == null
                    ? IconButton(
                        tooltip: 'Actions for ${host.name}',
                        visualDensity: VisualDensity.standard,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(width: navTrailW(), height: _mouse() ? 24 : 44),
                        style: IconButton.styleFrom(minimumSize: Size(navTrailW(), _mouse() ? 24 : 44), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => _hostMenu(context, host),
                        icon: Icon(Icons.more_horiz, size: 16, color: k.muted))
                    : IconButton(
                        tooltip: 'Retry',
                        visualDensity: VisualDensity.standard,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(width: navTrailW(), height: _mouse() ? 24 : 44),
                        style: IconButton.styleFrom(minimumSize: Size(navTrailW(), _mouse() ? 24 : 44), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: feed.refresh,
                        icon: Icon(Icons.refresh, size: 16, color: k.muted)),
              ),
            ),
          ),
          if (!folded) ..._usageRows(context, host),
          if (!folded) ...[
          if (projects.isEmpty)
            _Row(
                label: feed.error != null ? 'Can\'t load projects.' : feed.loaded ? 'No projects yet.' : 'Loading…',
                labelColor: k.muted,
                selected: false,
                onTap: null),
          for (final (i, p) in projects.indexed)
            _ProjectGroup(
              host: host,
              project: p,
              gapAbove: i == 0 && hasUsage ? 5 : 6,
              panel: panel,
              onPick: () => onPick(p.path),
              onRig: (r, {enlarge}) => onRig(p.path, p.name, r, enlarge: enlarge),
            ),
          NavRow(
            leading: Icon(Icons.add, size: 16, color: feed.error != null ? k.muted : k.ink),
            label: 'Add project folder',
            dashed: true,
            dimmed: feed.error != null,
            endLabel: feed.error == null
                ? null
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 80),
                    child: Text('host offline', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted))),
            onTap: feed.error != null ? null : onAdd),
          ],
        ]);
      },
    );
  }
}

/// A project: its row (fold chevron, folder, bold name, the working · waiting tally), then its rigs (the ones that need you
/// first), then the agents and shells running in it outside a rig, level with the rigs: an agent outside a rig is the one
/// that sits directly under the project. Subagents and shells nest under the agent that started them.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup(
      {required this.host,
      required this.project,
      this.gapAbove = 6,
      required this.panel,
      required this.onPick,
        required this.onRig});
  final Host host;
  final Project project;

  /// The space above its row: 6 between projects, 5 under the host's usage line so the first lands on the rows' 28 pitch.
  final double gapAbove;
  final String? panel;
  final VoidCallback onPick;
  final void Function(RigWithSeats rig, {String? enlarge}) onRig;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final p = project;
    final t = SeatTally(host, p.rigs, p.loose, project: p);
    // The Rigs home's order: needs you, working, shells, idle, then by name; a change of tier held 5 minutes (StableTiers),
    // never by activity time, so rows don't jump under the pointer.
    final now = homeNow();
    // What runs where: the main checkout's things sit directly under the project, each worktree with something running gets a
    // row of its own (groupByWorktree: names from the path, no git call). A rig is in one place, with all its seats; each
    // group's rows keep the order above.
    final groups = <_WtGroup>[];
    for (final g in groupByWorktree(p)) {
      String suffix(RigWithSeats r) => g.name == null ? '' : '@${g.name}';
      final rigs = homeOrder.sorted<RigWithSeats>([for (final r in g.rigs) if (r.rig.status != 'stopped') r],
          key: (r) => Fleet.rigKey(host, r) + suffix(r),
          raw: rigTier,
          name: (r) => host.rigLabel(r.rig.name),
          asked: (r) => [for (final s in r.seats) if (s.state == SeatState.needsYou && s.waitingSince != null) s.waitingSince!].firstOrNull ?? now);
      final loose = homeOrder.sorted<LooseAgent>([for (final a in g.loose) if (looseRecent(host, a, now)) a],
          key: (a) => 'a:${host.id}|${a.id}', raw: (a) => looseTier(host, a), name: (a) => a.name);
      if (rigs.isNotEmpty || loose.isNotEmpty || g.shells.isNotEmpty) groups.add(_WtGroup(g.name, rigs, loose, g.shells));
    }
    // The main checkout first, then the worktrees by name: the order does not depend on the feed's.
    groups.sort((a, b) => a.name == null ? (b.name == null ? 0 : -1) : (b.name == null ? 1 : a.name!.compareTo(b.name!)));
    final hasKids = groups.isNotEmpty;
    // A rig shows in the active view when one of its seats is active, a loose agent when it is (the one rule: Fleet.stateActive).
    bool rigActive(RigWithSeats r) => r.seats.any(Fleet.seatActive);
    bool isLooseActive(LooseAgent a) => looseActive(host, a);
    final key = Fleet.folderKey(host, p.path);
    final anyActive = groups.any((g) => g.rigs.any(rigActive) || g.loose.any(isLooseActive));
    final view = fleet.viewOf(key, anyActive, start: RigView.all);
    final selected = panel == 'project:${p.path}';
    final onPath = panel != null &&
        (p.rigs.any((r) => _inRig(panel!, r.rig.id)) || p.loose.any((a) => panel == seatPanelKey(a.toSeat())));
    void more() {
      useHost(context, host);
      // Found now: the row is gone by the time Unpin has finished.
      final shell = context.findAncestorStateOfType<_AppShellState>();
      showProjectActions(context, p.path,
          onOpen: onPick,
          view: hasKids ? view : null,
          anyActive: anyActive,
          onView: (v) => fleet.setView(key, v),
          onUnpinned: () => shell?._unpinned(p.path));
    }

    final working = t.counts[Status.working] ?? 0, waiting = t.counts[Status.needsYou] ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: gapAbove),
      _Row(
        level: _Level.project,
        // As on the Rigs home: orange when an agent needs you, green when some work, grey otherwise.
        leading: AppIcon(AppIconKind.folder, size: 16, color: folderColor(k, needs: t.needs, working: t.working)),
        label: p.name,
        words: t.words(),
        tally: working + waiting == 0
            ? null
            : Text.rich(TextSpan(style: mono(context, color: k.muted), children: [
                TextSpan(text: '$working'),
                const TextSpan(text: ' · '),
                TextSpan(text: '$waiting', style: TextStyle(color: waiting > 0 ? k.accent : null)),
              ])),
        view: hasKids ? view : null,
        // The chevron cycles collapsed, active only, all; the long-press list sets one directly.
        onFold: () => fleet.cycle(key, anyActive, start: RigView.all),
        selected: selected,
        onPath: onPath,
        onTap: onPick,
        onMore: more,
        moreButton: false,
      ),
      if (hasKids && view != RigView.collapsed)
        for (final g in groups)
          ..._worktreeLevel(context, g, view, rigActive, isLooseActive, anyActive),
      if (hasKids && view == RigView.active && !anyActive) _noActive(context, 1),
    ]);
  }

  /// One group's rows, directly under the project (level 1), main checkout and worktrees alike (the worktree is a second line on
  /// each row). [view] is the project's: all, active only, or folded.
  List<Widget> _worktreeLevel(BuildContext context, _WtGroup g, RigView view, bool Function(RigWithSeats) rigActive,
      bool Function(LooseAgent) looseActive, bool anyActive) {
    final p = project;
    final name = g.name;
    // Rigs, loose agents and shells sit directly under their project; the worktree each runs in is a second line on its row.
    final showRigs = view == RigView.all ? g.rigs : [for (final r in g.rigs) if (view == RigView.active && rigActive(r)) r];
    final showLoose = view == RigView.all ? g.loose : [for (final a in g.loose) if (view == RigView.active && looseActive(a)) a];
    final showShells = view == RigView.all ? g.shells : const <ProjectShell>[];
    const depth = 1;
    final suffix = name == null ? '' : '@$name';
    Widget rig(RigWithSeats r) => _RigGroup(
        host: host,
        panel: panel,
        rig: r,
        projectName: p.name,
        depth: depth,
        keySuffix: suffix,
        onTiles: () => onRig(r),
        // An agent with a tile opens enlarged in the tiles, as a double click there does, unless the setting is Chat
        // (then its chat); a shell its screen.
        onSeat: (s) => TilesScreen.tiled(s) && !opensAsChat(s)
            ? onRig(r, enlarge: s.logicalId)
            : detailNavigator(context).push(MaterialPageRoute<void>(builder: (_) => seatScreen(r.rig.name, s))));
    final rows = <Widget>[
      for (final r in showRigs) rig(r),
      // Agents outside a rig, level with the rigs.
      for (final a in showLoose) ..._looseRows(context, host, a, p.rigs, panel, depth, p.name),
      // Project shells (tmux rp-*): the same row, a shell icon.
      for (final sh in showShells)
        _Row(
          level: _Level.agent,
          depth: depth + 1,
          guides: depth,
          agentStatus: Status.idle,
          kind: StatusKind.shell,
          label: host.shellLabel(sh.name),
          wtLine: worktreeName(sh.cwd),
          selected: false,
          onTap: () {
            useHost(context, host);
            openShell(context, sh);
          },
          onMore: () {
            useHost(context, host);
            showShellActions(context, host, sh);
          },
        ),
    ];
    return rows;
  }
}

/// One place of a project and what runs there: the main checkout ([name] null) or a worktree.
class _WtGroup {
  _WtGroup(this.name, this.rigs, this.loose, this.shells);
  final String? name;
  final List<RigWithSeats> rigs;
  final List<LooseAgent> loose;
  final List<ProjectShell> shells;
}

StatusIcon _kindIcon(StatusKind kind, Status status, Color ground, String? runtime) => switch (kind) {
      StatusKind.agent => StatusIcon.agent(status, compact: true, ground: ground, runtime: runtime),
      StatusKind.subagent => StatusIcon.subagent(status, ground: ground),
      StatusKind.shell => StatusIcon.shell(status, ground: ground),
    };

/// An agent outside a rig: its row (its runtime's logo in the state colour, name, age), then the subagents it runs.
List<Widget> _looseRows(BuildContext context, Host host, LooseAgent a, List<RigWithSeats> rigs, String? panel, int depth, String project) => [
      // At the depth of an agent under a rig (its label is at the same x), with only its project's guide above it.
      _Row(
        level: _Level.agent,
        depth: depth + 1,
        guides: depth,
        agentStatus: Status.of(looseState(host, a)),
        runtime: a.runtime,
        label: a.name,
        wtLine: worktreeName(a.cwd),
        ago: a.lastActivityAt == null ? null : ago(a.lastActivityAt),
        selected: panel == seatPanelKey(a.toSeat()),
        onTap: () {
          useHost(context, host);
          openLooseAgent(detailNavigator(context), a, rigs);
        },
        onMore: () {
          useHost(context, host);
          showLooseActions(context, a,
              onChat: () => openLooseAgent(detailNavigator(context), a, rigs, chat: true),
              onTerminal: () => detailNavigator(context).push(
                  MaterialPageRoute<void>(builder: (_) => TerminalScreen(target: SeatTarget('no rig', a.toSeat())))));
        },
      ),
      ..._subagentRows(context, host, a.toSeat(), depth + 1, () {
        useHost(context, host);
        openLooseAgent(detailNavigator(context), a, rigs);
      }, guides: depth),
      // A shell opens its agent's shells (live output, Stop).
      ..._jobRows(jobsOfLoose(host, a), depth + 1, (job) {
        useHost(context, host);
        detailNavigator(context).push(MaterialPageRoute<void>(
            builder: (_) => ShellsScreen(host: host, seat: a.toSeat(), title: a.name, project: project, tapped: job)));
      }, guides: depth),
    ];

/// A running rig: its row (fold chevron, rig icon, name), then its seats. Its seats fold as on the rig screen (the
/// working ones until folded or unfolded). The row opens its tiles, a seat the same tiles with it enlarged.
class _RigGroup extends StatelessWidget {
  const _RigGroup(
      {required this.host,
      required this.panel,
      required this.rig,
      required this.projectName,
      required this.onTiles,
      required this.onSeat,
      this.depth = 1,
      this.keySuffix = ''});
  final Host host;
  final String? panel;
  final RigWithSeats rig;
  final String projectName;

  /// The rig row's level: 1 under a project, 2 under a worktree row.
  final int depth;

  /// Tells a rig's rows apart when it is listed under two worktrees (its fold state is per row).
  final String keySuffix;
  final VoidCallback onTiles;
  final void Function(Seat seat) onSeat;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final r = rig;
    final key = Fleet.rigKey(host, r) + keySuffix;
    final seats = r.seats.where((s) => s.isAgent || s.state != SeatState.stopped).toList();
    // The same order as the Rigs home's card: tier, then the oldest ask first, then name.
    final now = homeNow();
    final shown = homeOrder.sorted<Seat>(fleet.rigSeatsShown(key, seats),
        key: (s) => '$key/${s.logicalId}', raw: seatTier, name: (s) => s.logicalId, asked: (s) => s.waitingSince ?? now);
    final view = fleet.rigView(key, seats);
    final name = host.rigLabel(r.rig.name);
    final t = SeatTally(host, [r], const []);
    final selected = panel == 'rig:${r.rig.id}';
    final onPath = panel != null && panel!.startsWith('seat:${r.rig.id}/');
    void more() {
      useHost(context, host);
      showRigActions(context, r.rig, r.seats,
          title: name,
          projectName: projectName,
          onOpen: onTiles,
          onOpenWorktree: worktreeName(r.primaryCwd) == null
              ? null
              : () {
                  final main = mainCheckout(r.primaryCwd!);
                  final project = fleet.feedFor(host).projects.where((q) => q.path == main).firstOrNull ?? Project(path: main);
                  openWorktreeScreen(context, host, project, worktreeName(r.primaryCwd)!);
                },
          view: seats.isEmpty ? null : view,
          anyActive: seats.any(Fleet.seatActive),
          onView: (v) => fleet.setView(key, v));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Row(
        level: _Level.rig,
        depth: depth,
        // The rig's top state over all its seats, folded ones too.
        // A seat that failed to launch makes the rig's mark red, folded or not.
        leading: AppIcon(AppIconKind.rig, size: 16, color: rigIconColor(k, r, host)),
        label: name,
        // Under a worktree row the worktree is the row above, not a chip.
        wtLine: worktreeName(r.primaryCwd),
        // The icon's colour in words (same order); a rig that needs you says so through its count.
        words: t.needs > 0 ? '' : t.working > 0 ? 'working' : t.shell > 0 ? 'waiting on shell' : 'idle',
        count: t.needs,
        view: seats.isEmpty ? null : view,
        onFold: () => fleet.cycleRig(key, seats),
        selected: selected,
        onPath: onPath,
        onTap: onTiles,
        onMore: more,
        moreButton: false,
      ),
      if (view == RigView.active && shown.isEmpty && seats.isNotEmpty) _noActive(context, depth + 1, asAgent: true),
      for (final s in shown) ...[
          _Row(
            level: _Level.agent,
            depth: depth + 1,
            agentStatus: s.launchFailed ? Status.failed : Status.of(s.state),
            runtime: s.runtime,
            label: s.logicalId,
            worktree: seatPlaceChip(s, r.primaryCwd),
            // Its own worktree, only when it is not the rig's.
            wtLine: worktreeName(s.cwd) != null && worktreeName(s.cwd) != worktreeName(r.primaryCwd) ? worktreeName(s.cwd) : null,
            ctx: s.launchFailed ? null : s.contextUsedPercent,
            ago: s.lastActivityAt == null ? null : ago(s.lastActivityAt),
            selected: panel == seatPanelKey(s),
            onTap: () => onSeat(s),
            onMore: () {
              useHost(context, host);
              showSeatSheet(context, r.rig.name, s);
            },
          ),
          ..._subagentRows(context, host, s, depth + 1, () => onSeat(s)),
          ..._jobRows(s.jobs, depth + 1, (job) {
            useHost(context, host);
            detailNavigator(context).push(MaterialPageRoute<void>(
                builder: (_) => ShellsScreen(host: host, seat: s, title: s.logicalId, project: projectName, rigName: r.rig.name, tapped: job)));
          }),
        ],
    ]);
  }
}

/// The one muted line under a row in its active-only view when nothing in it is active, so that view is seen and not taken for folded.
Widget _noActive(BuildContext context, int depth, {bool asAgent = false}) => _Row(
    level: _Level.agent,
    depth: depth,
    // Under a rig it reads as the empty list of its agents: its label starts where an agent's name would (their logo's wider gap).
    slot: asAgent ? _slotW + _agentGap - navIconGap : _slotW,
    label: 'No active agents',
    labelColor: Tokens.of(context).muted,
    selected: false,
    onTap: null);

/// What a screen reader (and the tooltip) hears for a row's chevron: its name and which children show.
String viewLabel(String name, RigView v) => switch (v) {
      RigView.collapsed => '$name collapsed',
      RigView.active => '$name showing active agents',
      RigView.all => '$name showing all agents',
    };

/// The host's Claude 5h and week usage as one compact display-only line under its name: '5h ▮▮▮ 71%  wk ▮▮ 34%', each bar in the
/// pace colour with a tick at the pace, the resets in a tooltip. Nothing for a host with no reading.
List<Widget> _usageRows(BuildContext context, Host host) => [
      ValueListenableBuilder(
        valueListenable: usageNow,
        builder: (context, _, __) {
          final now = HostUsageBar.clock();
          final readings = HostUsageBar.claudeReadings(host, now);
          if (readings.isEmpty) return const SizedBox.shrink();
          final said = [for (final w in readings) '${w.label} · resets in ${w.resetsIn(now)}, ${w.usedPercent}% used${w.stale(now) ? ', stale' : ''}'].join('; ');
          // Level with the host's name (the host row's own icon slot, empty), not the projects' indent.
          return _Row(
            level: _Level.host,
            leading: const SizedBox(width: 10, height: 18),
            slot: 10,
            compact: true,
            label: 'Claude usage',
            words: said,
            selected: false,
            onTap: null,
            body: ExcludeSemantics(child: HostUsageLine(host: host)),
          );
        },
      ),
    ];

/// The subagents [seat] is running, as muted child rows under it (running only: a row goes when its subagent
/// finishes). A tap opens the subagent's log, or the agent, [onOpen], when it has none yet.
List<Widget> _subagentRows(BuildContext context, Host host, Seat seat, int depth, VoidCallback onOpen, {int? guides}) => [
      for (final sub in fleet.feedFor(host).subagentsOf(seat))
        _Row(
          level: _Level.agent,
          depth: depth + 1,
          guides: guides,
          // The same row as an agent's (name, age), one indent under it; only the icon and its colour differ.
          agentStatus: Status.working,
          kind: StatusKind.subagent,
          label: sub.title,
          ago: (sub.lastWrite ?? sub.started) == null ? null : ago(sub.lastWrite ?? sub.started),
          words: 'subagent, running',
          selected: false,
          // Its own log as a chat; one with no log yet opens its agent.
          onTap: canOpenSubagent(sub) ? () => requestSubagent(host, seat, sub) : onOpen,
        ),
    ];

/// The shells an agent started (its Bash tool's processes), nested under it like its subagents: the same row, a blue
/// terminal icon, the command as its name and how long it has run as its age. A tap opens the agent.
List<Widget> _jobRows(List<AgentJob> jobs, int depth, void Function(AgentJob job) onOpen, {int? guides}) => [
      for (final j in jobs.where((j) => j.isShell))
        _Row(
          level: _Level.agent,
          depth: depth + 1,
          guides: guides,
          agentStatus: Status.working,
          kind: StatusKind.shell,
          label: j.short,
          ago: ago(homeNow().subtract(j.elapsed)),
          words: j.isMonitor ? 'monitor, running' : 'shell, running',
          selected: false,
          onTap: () => onOpen(j),
        ),
    ];

/// One row of the tree, the same everywhere: [depth] levels in, the icon slot (no fold slot: [view] puts a chevron at the right edge, only on
/// project and rig rows), the icon slot, the label, then what sits at the right edge. The guides of the
/// ancestors are drawn behind it, so they run unbroken down the rows.
class _Row extends StatelessWidget {
  const _Row({
    this.level,
    this.depth = 0,
    this.guides,
    this.leading,
    this.slot = _slotW,
    this.compact = false,
    this.agentStatus,
    this.kind = StatusKind.agent,
    this.runtime,
    this.worktree,
    this.wtLine,
    this.body,
    required this.label,
    this.labelColor,
    this.words = '',
    this.ctx,
    this.ago,
    this.count = 0,
    this.tally,
    required this.selected,
    this.onPath = false,
    required this.onTap,
    this.view,
    this.onFold,
    this.onMore,
    this.moreButton = true,
  });
  final _Level? level;
  final int depth;

  /// How many ancestor guides to draw when that is not [depth] (a loose agent sits at an agent's depth with only its project above it).
  final int? guides;
  final Widget? leading;

  /// The icon slot's width: the host's usage line takes the host swatch's 10 so it starts level with the host name.
  final double slot;

  /// An agent's row: its runtime's logo in this status's colour in place of [leading]. No rig badge: the tree nests rig agents.
  final Status? agentStatus;

  /// The icon's kind: an agent's logo, a subagent's fork, a shell's terminal. A subagent has the state dot; an agent's state is
  /// its icon's colour.
  final StatusKind kind;

  /// An agent's runtime: its logo is the icon, in the state's colour.
  final String? runtime;

  /// The worktree chip after the label: only a worktree that is not main.
  final String? worktree;

  /// The second line: the worktree this row runs in (its glyph and name, muted), from the name's column. Null in the main checkout.
  final String? wtLine;
  final String label;

  /// Drawn in place of the label's text (the host's usage strip); [label] still says it to a screen reader.
  final Widget? body;
  final Color? labelColor;

  /// Said to a screen reader after the label, in place of a visual [tally].
  final String words;

  /// The agent's context used, in percent: small tabular text at the right edge, when the seat reports one.
  final double? ctx;

  /// How long since the agent last worked ("2m"), small mono text before the context. Real work time (its last reply or
  /// hook event), not the pane's.
  final String? ago;


  /// A read-only row: smaller text, about half the height. With a mouse the whole row is the tap target; on touch it
  /// is display only (the host's usage lines).
  final bool compact;

  /// Agents waiting on you, shown as a count.
  final int count;
  final Widget? tally;

  /// Null: nothing to fold. Otherwise which children show; the chevron at the right edge calls [onFold].
  final RigView? view;
  final VoidCallback? onFold;

  final bool selected;

  /// Holds what is selected (a rig or project of the agent on show): a heavier name, without the selected fill.
  final bool onPath;
  final VoidCallback? onTap;

  /// The row's action list: a ⋯ button, a long press and a right click all open it.
  final VoidCallback? onMore;

  /// False: [onMore] is reached by long press and right click only (project and rig rows).
  final bool moreButton;

  @override
  Widget build(BuildContext context) => HoverBuilder(builder: _build);

  Widget _build(BuildContext context, bool hovered) {
    final k = Tokens.of(context);
    final said = [if (words.isNotEmpty) words, if (count > 0) '$count need you'].join(', ');
    final onTap = this.onTap;
    final rowH = _rowHeight(compact: compact);
    final twoLines = !compact && (ctx != null || wtLine != null);
    final labelGap = agentStatus != null ? _agentGap : navIconGap;
    // The ⋯ and the chevron's hit area: taller than the name line, centred on it.
    final tapH = _mouse() ? 28.0 : 44.0;
    final row = Semantics(
      selected: selected,
      button: onTap != null,
      label: said.isEmpty ? null : '$label, $said',
      child: Material(
        color: selected ? k.ground : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
          side: BorderSide(color: selected ? k.border : Colors.transparent),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: onTap,
          onLongPress: onMore,
          onSecondaryTap: onMore,
          child: CustomPaint(
            // A subagent's or shell's own parent is an agent, which has no guide under it: the guides stop at the rig's.
          painter: _Guides(guides ?? (kind == StatusKind.agent ? depth : depth - 1), k.border),
            child: Padding(
              // One line: 7 above and below with a mouse; with a second line (context bar, worktree) 4. A finger's row stays 48.
              padding: EdgeInsets.fromLTRB(navFillInset + depth * _indent, compact ? 0 : navRowTop(twoLines: twoLines), navFillInset,
                  compact || !_mouse() ? 0 : (twoLines ? 4 : 7)),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: compact ? rowH : (_mouse() ? 0 : 48 - navRowTop(twoLines: twoLines))),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // The first line: everything on it is centred on the name line (y 16 plain, 13 with a second line).
                  SizedBox(
                    height: compact ? rowH : navNameLineH,
                    child: Row(children: [
                      // The icon and the gap; the fold chevron, where there is one, is at the right edge.
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: slot,
                            child: Center(
                                child: agentStatus == null
                                    ? leading
                                    // The glyph is 17-18dp in a 16dp slot: it may overhang by a dp each side.
                                    : SizedBox(
                                        width: _slotW,
                                        height: 18,
                                        child: OverflowBox(
                                            minWidth: 18,
                                            maxWidth: 18,
                                            minHeight: 18,
                                            maxHeight: 18,
                                            child: _kindIcon(kind, agentStatus!, selected ? k.ground : k.headerFill, runtime))))),
                        // An agent's icon is wider than a folder's or rig's, so its name sits further out.
                        SizedBox(width: labelGap),
                      ]),
                      Expanded(
                        child: Row(children: [
                          Flexible(
                            child: body ?? Text(level == _Level.host ? label.toUpperCase() : label,
                                style: _labelStyle(context, level, color: labelColor, strong: onPath || selected)
                                    .copyWith(color: level == null || level == _Level.agent ? labelColor : null, fontSize: compact ? 11 : null),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (worktree != null) ...[const SizedBox(width: 6), WorktreeChip(worktree!)],
                        ]),
                      ),
                      if (count > 0)
                        ExcludeSemantics(
                          child: Text('$count', style: mono(context, color: k.accent, weight: FontWeight.w600)),
                        ),
                      if (tally != null) ExcludeSemantics(child: Padding(padding: const EdgeInsets.only(left: 6), child: tally)),
                      if (ago case final a?)
                        ExcludeSemantics(
                          // A column of its own (right-aligned), so the age never runs into what sits beside it.
                          child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: SizedBox(width: 28, child: Text(a, textAlign: TextAlign.right, style: mono(context, size: 11, color: k.muted)))),
                        ),
                      // The one trailing column (24 with a mouse, 44 for a finger): the fold chevron, or the ⋯ with a mouse (shown on
                      // hover or when selected, its room kept; a finger long-presses the row). Counts and ages end at its left edge.
                      if (!compact)
                        SizedBox(
                          width: navTrailW(),
                          child: OverflowBox(
                            minHeight: 0,
                            maxHeight: tapH,
                            child: SizedBox(
                              width: navTrailW(),
                              height: tapH,
                              child: view != null
                                  ? Semantics(
                                      button: true,
                                      label: viewLabel(label, view!),
                                      onTap: onFold,
                                      excludeSemantics: true,
                                      child: Tooltip(
                                        message: viewLabel(label, view!),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(kRadius),
                                          onTap: onFold,
                                          child: Center(
                                            child: AnimatedRotation(
                                                turns: switch (view!) { RigView.collapsed => 0, RigView.active => 0.125, RigView.all => 0.25 }, // right, slanted (active only), down
                                                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
                                                child: Icon(Icons.chevron_right, size: 16, color: k.muted)),
                                          ),
                                        ),
                                      ),
                                    )
                                  : (onMore != null && moreButton && _mouse())
                                      ? Opacity(
                                          opacity: hovered || selected ? 1 : 0,
                                          child: IgnorePointer(
                                            ignoring: !(hovered || selected),
                                            child: Center(
                                              child: IconButton(
                                                tooltip: 'Actions for $label',
                                                padding: EdgeInsets.zero,
                                                constraints: BoxConstraints.tightFor(width: navTrailW(), height: tapH),
                                                style: IconButton.styleFrom(minimumSize: Size(navTrailW(), tapH), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                                onPressed: onMore,
                                                icon: Icon(Icons.more_horiz, size: 16, color: k.muted),
                                              ),
                                            ),
                                          ),
                                        )
                                      : null,
                            ),
                          ),
                        ),
                    ]),
                  ),
                  // The second line, from the name's column: the worktree (its glyph, 4, its name; mono 11, muted, one line, ending where the
                  // counts do) with the context's percent at its right end when the seat has one.
                  if (wtLine != null)
                    SizedBox(
                      height: navSecondLineH,
                      child: Padding(
                        padding: EdgeInsets.only(left: slot + labelGap, right: ctx == null ? navTrailW() : 0),
                        child: Row(children: [
                          Expanded(
                            child: Row(children: [
                              AppIcon(AppIconKind.worktree, size: 12, color: k.muted),
                              const SizedBox(width: 4),
                              Flexible(child: Text(wtLine!, style: mono(context, size: 11, color: k.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                          if (ctx != null) ExcludeSemantics(child: _ctxPercent(context, k, ctx!)),
                        ]),
                      ),
                    ),
                  // The context bar: full width from the name's column, 3dp. Alone it has its own 10dp line with its percent at the right; under a
                  // worktree line it is a 4dp strip (1 gap, the bar) and the percent is on that line.
                  if (ctx case final c?)
                    ExcludeSemantics(
                      child: SizedBox(
                        height: wtLine != null ? 4 : 10,
                        child: Padding(
                          padding: EdgeInsets.only(left: slot + labelGap, top: 1),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: ContextBar(c, height: 3, base: k.muted, label: false)),
                            const SizedBox(width: 6),
                            wtLine != null
                                ? SizedBox(width: navTrailW())
                                // The percent is centred on the bar's own height, under the row's ⋯.
                                : SizedBox(width: navTrailW(), height: 3, child: OverflowBox(minHeight: 0, maxHeight: 14, child: _ctxPercent(context, k, c))),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(padding: EdgeInsets.symmetric(horizontal: _sideInset), child: row);
  }
}

/// The context's percent in the one trailing column's width, centred under the row's ⋯, coloured by how full it is.
Widget _ctxPercent(BuildContext context, Tokens k, double c) => SizedBox(
      width: navTrailW(),
      child: Center(
        child: Text('${c.round()}%',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: mono(context, size: 11, color: contextColor(c, k))
                .copyWith(fontWeight: contextWeight(c), fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    );

/// A 1dp line down the middle of each ancestor's fold slot, the full height of the row.
class _Guides extends CustomPainter {
  _Guides(this.depth, this.color);
  final int depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < depth; i++) {
      canvas.drawRect(Rect.fromLTWH(navFillInset + i * _indent + _slotW / 2, 0, 1, size.height), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_Guides old) => old.depth != depth || old.color != color;
}
