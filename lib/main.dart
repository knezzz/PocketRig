import 'dart:io';

import 'package:borealis/borealis.dart';
import 'package:flutter/material.dart';
import 'package:loggy/loggy.dart';

import 'api/client_cache.dart';
import 'api/openrig_client.dart';
import 'data/chat_cache.dart';
import 'data/media_cache.dart';
import 'data/drafts.dart';
import 'data/outbox.dart';
import 'data/push.dart';
import 'data/host_store.dart';
import 'data/usage_rings.dart';
import 'data/ux_log.dart';
import 'models.dart';
import 'ssh/host_keys.dart';
import 'ssh/ssh_log.dart';
import 'ui/agent_panels.dart';
import 'ui/appearance.dart';
import 'ui/debug_overlay_setting.dart';
import 'ui/deep_links.dart';
import 'ui/desktop_shell.dart';
import 'ui/needs_you_banner.dart';
import 'ui/desktop_menu.dart' show trackMenuAnchor;
import 'ui/open_agents_on.dart';
import 'ui/status_shape.dart' show warmRuntimeLogos;
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Logs tab of the Borealis panel; console too via its forward printer.
  Loggy.initLoggy(logPrinter: BorealisPrinter());
  final store = HostStore();
  await store.load();
  await loadAppearance();
  await loadDebugOverlay();
  await loadOpenAgentsOn();
  await loadAgentPanels();
  persistHostKeys = store.save;
  chatCache = ChatCache.open();
  mediaCache = MediaCache(chatCache!);
  outbox = await Outbox.open();
  drafts = await Drafts.open();
  await uxLog.start();
  // Home-screen widgets read what this writes; they never call the daemon.
  UsageRingsRefresher(store).start();
  AppLifecycleListener(onStateChange: (s) => windowActive.value = s == AppLifecycleState.resumed);
  await warmRuntimeLogos();
  runApp(PocketRigApp(store: store));
}

/// Gives every screen the host store and a client for the active host.
class AppScope extends InheritedNotifier<HostStore> {
  const AppScope({super.key, required HostStore store, required super.child}) : super(notifier: store);

  /// In build: rebuilds when hosts change.
  static HostStore of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Outside build (callbacks, timers): no rebuild dependency.
  static HostStore read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// One client per host connection setting, reused across rebuilds. When
  /// the active host (or its address) changes, the old clients are closed so
  /// their sockets and event streams don't linger.
  static OpenRigClient? clientOf(BuildContext context) {
    final host = context.getInheritedWidgetOfExactType<AppScope>()?.notifier?.active;
    if (host == null) return null;
    return clientFor(host);
  }

  /// One client per host, kept while the host's connection settings stay the
  /// same: the Projects list talks to every host at once. A host whose
  /// address or port changed gets a new client, and the old one closes.
  static OpenRigClient clientFor(Host host) => cachedClient(host);

  /// Drops every cached client (tests swap the client factory between cases).
  @visibleForTesting
  static void resetClients() => resetCachedClients();
}

/// For opening screens from outside the widget tree (notification links).
final navigatorKey = GlobalKey<NavigatorState>();

class PocketRigApp extends StatefulWidget {
  const PocketRigApp({super.key, required this.store, this.deepLinks = true});
  final HostStore store;

  /// Off in widget tests, which have no platform link channel.
  final bool deepLinks;

  @override
  State<PocketRigApp> createState() => _PocketRigAppState();
}

class _PocketRigAppState extends State<PocketRigApp> {
  late final DeepLinks? _links = widget.deepLinks ? (DeepLinks(widget.store, navigatorKey)..start()) : null;

  // Tokens go to every host that has notifications set up; a failed host is skipped (the next launch retries).
  late final Push? _push = _links == null
      ? null
      : (Push(
          onOpen: (l) => _links.handle(Uri.parse(l)),
          onDevice: (d) {
            for (final h in widget.store.hosts) {
              if (h.ntfyTopic != null && h.id != Host.localId) writeWatcherConfig(h, device: d).catchError((_) {});
            }
          },
        )..start());

  @override
  void initState() {
    super.initState();
    // Here, not in main(): the demo build has its own main, and its first menu would open at the window's top left.
    trackMenuAnchor();
    if (Platform.isIOS || Platform.isAndroid) _push;
  }

  @override
  void dispose() {
    _links?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return AppScope(
      store: store,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: appearance,
        builder: (context, mode, _) => MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [topRoute, uxRoutes],
          title: 'PocketRig',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Tokens.light, Brightness.light),
          darkTheme: buildTheme(Tokens.dark, Brightness.dark),
          themeMode: mode,
          // Follow the system text size (Dynamic Type), up to 2x so fixed
          // rows like the terminal keys stay usable.
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2.0,
            // Debug panel (network, logs, device, rendering flags) above everything.
            child: ValueListenableBuilder<bool>(
              valueListenable: debugOverlay,
              builder: (context, on, _) => BorealisOverlay(
                settings: BorealisSettings(enabled: on),
                pages: const [
                  WiretapBorealisPage(),
                  SshBorealisPage(),
                  LogsBorealisPage(),
                  UxBorealisPage(),
                  DeviceInfoBorealisPage(),
                  RenderingBorealisPage(),
                ],
                // The "needs you" banner floats over whichever screen is open.
                child: UxTaps(
                  child: Stack(children: [
                  child!,
                  // Desktop shows needs-you by the orange marks and counts alone.
                  if (!isDesktop)
                  Positioned(
                    left: 10,
                    right: 10,
                    top: MediaQuery.paddingOf(context).top + 6,
                    child: const NeedsYouBanner(),
                  ),
                ]),
                ),
              ),
            ),
          ),
          home: const AppShell(),
        ),
      ),
    );
  }
}
