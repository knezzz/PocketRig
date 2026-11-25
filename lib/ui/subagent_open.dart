import 'package:flutter/foundation.dart';

import '../data/subagents.dart';
import '../models.dart';
import 'chat_screen.dart';

/// The screen of a subagent: its own log as a read-only chat. [parent] is the agent that runs it. Every place that opens
/// a subagent (the chat's Subagents list, the sidebar's subagent rows) builds it here.
ChatScreen subagentScreen(Seat parent, Subagent sub) =>
    ChatScreen(rigName: parent.logicalId, seat: sub.toSeat(cwd: parent.cwd));

/// Whether [sub] has a log to open yet; one without opens its parent agent instead.
bool canOpenSubagent(Subagent sub) => sub.path != null;

/// A request from the sidebar to show [sub]'s screen in the content panel, which the shell answers (the sidebar sits
/// outside the panel's navigator). [lastSubagentRequest] is what to open; the counter makes a repeat notify.
final subagentRequests = ValueNotifier<int>(0);
({Host host, Seat parent, Subagent sub})? lastSubagentRequest;

void requestSubagent(Host host, Seat parent, Subagent sub) {
  lastSubagentRequest = (host: host, parent: parent, sub: sub);
  subagentRequests.value++;
}
