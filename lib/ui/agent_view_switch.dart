import 'package:flutter/material.dart';

import 'kit.dart' show navMouse;
import '../data/needs_you.dart' show needsYouAlerts;
import '../models.dart' show Seat;
import 'theme.dart';

/// Which of an agent's two screens is showing.
enum AgentView { terminal, chat }

/// Which of an agent's two views it has, and why one is missing: one rule for every screen that shows the switch.
class AgentViews {
  const AgentViews({this.terminalWhy, this.chatWhy});

  /// Why the view is unavailable (the switch's tooltip), or null when it is there.
  final String? terminalWhy, chatWhy;

  String? whyNot(AgentView v) => v == AgentView.terminal ? terminalWhy : chatWhy;
}

/// The views [seat] has: the terminal needs its tmux session; the chat needs that and Claude Code, whose session log it reads.
AgentViews agentViews(Seat? seat) {
  const noSession = 'No tmux session';
  final session = seat?.sessionName != null;
  return AgentViews(
    terminalWhy: session ? null : noSession,
    chatWhy: seat == null || !seat.isClaude ? 'Chat needs Claude Code\'s session log' : (session ? null : noSession),
  );
}

/// The Terminal | Chat switch in an agent screen's header (desktop and phone share it). [onChanged] fires only when the
/// other side is tapped; the screen does the going there.
class AgentViewSwitch extends StatelessWidget {
  const AgentViewSwitch({super.key, required this.showing, required this.onChanged, this.views = const AgentViews()});
  final AgentView showing;

  /// A view that is not there is dimmed, with its reason as a tooltip, and doesn't go anywhere. Never hidden.
  final AgentViews views;
  final ValueChanged<AgentView> onChanged;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    // 28dp inside the pill with a mouse; a finger gets a 44dp tap height.
    final h = navMouse() ? 28.0 : 44.0;
    Widget tab(AgentView v, String label) {
      final on = v == showing;
      final why = on ? null : views.whyNot(v);
      final go = on || why != null ? null : () => onChanged(v);
      final tab = Semantics(
        button: true,
        selected: on,
        enabled: why == null,
        label: why == null ? label : '$label, unavailable: $why',
        // The tab on show is a button that goes nowhere; only a missing view has no action.
        onTap: why != null ? null : (on ? () {} : go),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: go,
          child: Container(
            height: h,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? k.border : Colors.transparent, borderRadius: BorderRadius.circular(4)),
            child: Text(label,
                style: TextStyle(fontSize: 12, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? k.ink : (why != null ? k.faint : k.muted))),
          ),
        ),
      );
      return why == null
          ? tab
          : MouseRegion(cursor: SystemMouseCursors.forbidden, child: Tooltip(message: why, triggerMode: TooltipTriggerMode.tap, child: tab));
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
          color: k.ground, border: Border.all(color: k.border), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        tab(AgentView.terminal, 'Terminal'),
        const SizedBox(width: 2),
        tab(AgentView.chat, 'Chat'),
      ]),
    );
  }
}

/// The route for going between an agent's terminal and chat: a short cross-fade, like a tab change, not a page slide
/// (none when the system asks for no animation).
Route<T> agentViewRoute<T>(BuildContext context, WidgetBuilder builder) {
  final still = MediaQuery.disableAnimationsOf(context);
  return PageRouteBuilder<T>(
    transitionDuration: still ? Duration.zero : const Duration(milliseconds: 150),
    reverseTransitionDuration: still ? Duration.zero : const Duration(milliseconds: 150),
    pageBuilder: (context, _, __) => builder(context),
    transitionsBuilder: (_, animation, __, child) => FadeTransition(opacity: animation, child: child),
  );
}

/// Goes to an agent's other view (chat to terminal or back) in this screen's place: the route is replaced, not stacked, so
/// switching views adds no page and Back from either leaves the agent for where it came from. [session] is the seat's
/// session: the screen it replaces lets go of the alerts focus as it goes, so the new one takes it again.
void switchAgentView(BuildContext context, WidgetBuilder builder, {String? session}) {
  final route = ModalRoute.of(context);
  final next = agentViewRoute<void>(context, builder);
  final nav = Navigator.of(context);
  if (route == null) {
    nav.push(next);
    return;
  }
  nav.replace(oldRoute: route, newRoute: next);
  // shortcut: a short delay after the old screen's dispose; a callback on its removal would be exact.
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    if (next.isActive) needsYouAlerts.focusedSession = session;
  });
}
