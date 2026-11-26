import 'package:flutter/material.dart';

import '../data/host_store.dart';
import '../main.dart';
import '../data/needs_you.dart';
import '../models.dart';
import '../terminal/transport.dart';
import 'answer_bar.dart';
import 'permission_card.dart' show PermissionCode;
import 'chat_screen.dart';
import 'desktop_shell.dart';
import 'inbox/answering.dart';
import 'recent_screen.dart' show askReply;
import 'status_shape.dart';
import 'theme.dart';

export '../data/needs_you.dart' show NeedsYouAlerts, SeatAlert, needsYouAlerts;

/// Routes whose screen is a seat's chat or terminal. Opening a seat from
/// the banner or a notification replaces the one on top instead of
/// stacking chats under chats.
final seatScreenRoutes = <Route<dynamic>>{};

/// Which route is on top of the app's navigator.
class TopRouteObserver extends NavigatorObserver with ChangeNotifier {
  Route<dynamic>? current;

  void _set(Route<dynamic>? route) {
    current = route;
    refresh();
  }

  /// Tells listeners (the banner) the top route or what it shows changed, after the frame the navigator is in.
  void refresh() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => notifyListeners())
      ..scheduleFrame();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _set(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _set(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _set(newRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (current == route) _set(previousRoute);
  }
}

/// The routes of a seat's terminal (a subset of [seatScreenRoutes]). Answers are not offered over a terminal: the banner
/// there only says who is waiting and opens the chat, where the answer buttons are.
final terminalRoutes = <Route<dynamic>>{};

final topRoute = TopRouteObserver();

/// Pushes [screen], or swaps it in for the seat chat or terminal on top.
void openSeatScreen(NavigatorState nav, Widget screen) {
  final route = MaterialPageRoute<void>(builder: (_) => screen);
  final top = topRoute.current;
  if (top != null && seatScreenRoutes.contains(top)) {
    nav.pushReplacement(route);
  } else {
    nav.push(route);
  }
}

/// Opens [seat] the way the rig screen does: chat for Claude Code seats,
/// the terminal otherwise.
void openSeatFromAlert(String rigName, Seat seat, {bool chat = false}) {
  final screen = chat ? ChatScreen(rigName: rigName, seat: seat, asChat: true) : seatScreen(rigName, seat);
  if (shownDetailPane() case final pane?) {
    pane.push(MaterialPageRoute<void>(builder: (_) => screen));
    return;
  }
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  openSeatScreen(nav, screen);
}

/// Asks the home screen to show the Inbox tab (the banner's "Inbox" link).
/// Bumped each time; the shell listens.
final inboxRequests = ValueNotifier<int>(0);

/// Back to the home screen, on the Inbox tab.
void openInbox() {
  final nav = navigatorKey.currentState;
  nav?.popUntil((r) => r.isFirst);
  inboxRequests.value++;
}

/// Board 6b: a compact card over whatever screen is open when a seat starts
/// waiting: who is asking and where, the exact ask, and the answer right
/// there (Deny · Always · Allow once, then Open; a question: Reply · Open). ✕ dismisses,
/// a swipe up snoozes that seat's banner for ten minutes, and "+N more
/// waiting · Inbox" goes to the rest.
class NeedsYouBanner extends StatelessWidget {
  const NeedsYouBanner({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([needsYouAlerts, needsYouCount, topRoute]),
        builder: (context, _) {
          final a = needsYouAlerts.current;
          // In from the top edge; out faster than in. With reduced motion it only fades.
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            reverseDuration: const Duration(milliseconds: 150),
            switchInCurve: kEaseOut,
            switchOutCurve: kEaseOut,
            transitionBuilder: (child, anim) => MediaQuery.disableAnimationsOf(context)
                ? FadeTransition(opacity: anim, child: child)
                : SlideTransition(
                    position: Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(anim),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
            child: a == null
                ? const SizedBox.shrink(key: ValueKey('none'))
                : Dismissible(
                    key: ValueKey('banner ${a.key}'),
                    direction: DismissDirection.up,
                    onDismissed: (_) => needsYouAlerts.snooze(a),
                    child: _BannerCard(key: ValueKey(a.key), alert: a),
                  ),
          );
        },
      );
}

class _BannerCard extends StatefulWidget {
  const _BannerCard({super.key, required this.alert});
  final SeatAlert alert;

  @override
  State<_BannerCard> createState() => _BannerCardState();
}

class _BannerCardState extends State<_BannerCard> {
  bool _busy = false;

  /// Opens the seat, switching to its host first: seat screens talk to the active host.
  static void _openWith(HostStore? store, SeatAlert a, {bool chat = false}) {
    needsYouAlerts.dismiss(a);
    if (store != null && store.active?.id != a.host.id && store.hosts.any((h) => h.id == a.host.id)) store.select(a.host.id);
    openSeatFromAlert(a.rig.name, a.seat, chat: chat);
  }

  HostStore? get _store => context.getInheritedWidgetOfExactType<AppScope>()?.notifier;

  Future<void> _answer(SeatAnswer answer, {String? scope}) async {
    final a = widget.alert;
    final store = _store;
    setState(() => _busy = true);
    await answerSeatOn(context, a.host, a.seat, answer, scope: scope, onOpen: () => _openWith(store, a));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reply() async {
    final a = widget.alert;
    final sheet = navigatorKey.currentContext;
    final session = a.seat.sessionName;
    if (sheet == null || session == null) return _openWith(_store, a);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final k = Tokens.of(context);
    final text = await askReply(sheet, a.seat.logicalId);
    if (text == null || text.trim().isEmpty) return;
    if (await sendTo(messenger, k, a.host, a.seat, text.trim(), 'Sent · ${a.seat.logicalId}')) {
      needsYouAlerts.answered(a.seat);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final a = widget.alert;
    final ask = a.ask;
    final store = _store;
    final canAnswer = a.seat.sessionName != null && !_busy;
    final overTerminal = terminalRoutes.contains(topRoute.current);
    final more = [needsYouAlerts.queued - 1, needsYouCount.value - 1].reduce((x, y) => x > y ? x : y);
    void openInboxFromBanner() {
      needsYouAlerts.dismiss(a);
      openInbox();
    }

    final detail = a.isPermission && ask.tool != null ? '${ask.tool} · ${ask.detail}' : ask.detail;
    final worktree = worktreeName(a.seat.cwd) ?? 'main checkout';
    final outlined = OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10), side: BorderSide(color: k.border));
    final filled = FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10));
    return Semantics(
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: 'Needs you: ${a.seat.logicalId} ${a.isPermission ? 'needs approval' : 'asked a question'}, '
          'rig ${a.rig.name}, worktree $worktree, ${a.project ?? ''} on ${a.host.name}',
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: k.surface,
            border: Border.all(color: k.accent),
            borderRadius: BorderRadius.circular(kRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 2, 0),
              child: Row(children: [
                const StatusShape(Status.needsYou, size: 10, semantics: false),
                const SizedBox(width: 10),
                // The top line opens the agent: no button for it under a permission's answers.
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Open ${a.seat.logicalId}',
                    onTap: () => _openWith(store, a, chat: overTerminal),
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: () => _openWith(store, a, chat: overTerminal),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(children: [
                          Expanded(child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: a.seat.logicalId, style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(
                        text: ' ${[
                          a.isPermission ? 'needs approval' : 'asked a question',
                          a.rig.name,
                          if (a.project != null) a.project!,
                        ].join(' · ')}',
                        style: TextStyle(color: k.muted),
                      ),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  )),
                          // It opens the agent.
                          Icon(Icons.chevron_right, size: 18, color: k.faint),
                        ]),
                      ),
                    ),
                  ),
                ),
                // No tooltip: the banner sits above the Navigator's overlay.
                Semantics(
                  container: true,
                  button: true,
                  label: 'Dismiss',
                  onTap: () => needsYouAlerts.dismiss(a),
                  excludeSemantics: true,
                  child: InkResponse(
                    onTap: () => needsYouAlerts.dismiss(a),
                    radius: 22,
                    child: SizedBox(width: 44, height: 44, child: Icon(Icons.close, size: 18, color: k.muted)),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                if (a.isPermission)
                  PermissionCode(detail, maxLines: 3)
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
                    child: Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  ),
                // Over a terminal there are no answers: the top line opens the chat, where they are.
                if (!overTerminal) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    if (a.isPermission)
                      // The one answer bar every surface uses (Deny · Allow once, Always "scope" under them).
                      Expanded(
                        child: AnswerBar(
                          busy: !canAnswer,
                          alwaysScope: ask.alwaysScope,
                          onDeny: () => _answer(SeatAnswer.deny),
                          onAlways: () => _answer(SeatAnswer.allowAlways, scope: ask.alwaysScope),
                          onAllow: () => _answer(SeatAnswer.allowOnce),
                        ),
                      )
                    else ...[
                      Expanded(
                        child: OutlinedButton(
                            onPressed: canAnswer ? _reply : null, style: outlined, child: const Text('Reply')),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: FilledButton(onPressed: () => _openWith(store, a), style: filled, child: const Text('Open')),
                      ),
                    ],
                  ]),
                ],
                if (more > 0)
                  Semantics(
                    button: true,
                    label: '$more more waiting. Open the Inbox',
                    onTap: openInboxFromBanner,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: openInboxFromBanner,
                      child: SizedBox(
                        height: 32,
                        // Hugs the left, like the rows above.
                        child: Row(children: [
                          Text('+$more more waiting', style: TextStyle(fontSize: 12, color: k.muted)),
                          const SizedBox(width: 6),
                          const Text('Inbox',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
            // Swipe up to snooze.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(color: k.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
