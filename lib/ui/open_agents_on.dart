import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'agent_view_switch.dart';

/// Which screen an agent with a tmux session opens on, from Settings › App: its terminal (the default) or its chat.
/// Kept in a small file next to the app's other data. A subagent log, a just-started session and one without a
/// session always open the chat.
final openAgentsOn = ValueNotifier<AgentView>(AgentView.terminal);

const _file = 'open-agents-on';

/// Where the choice is saved. Tests point it at a temp file.
Future<File?> Function() openAgentsOnFile = _path;

Future<File?> _path() async {
  try {
    return File('${(await getApplicationSupportDirectory()).path}/$_file');
  } catch (_) {
    return null; // tests and platforms without a support folder: keep the default
  }
}

/// Reads the saved choice, if any.
Future<void> loadOpenAgentsOn() async {
  try {
    final f = await openAgentsOnFile();
    if (f == null || !await f.exists()) return;
    openAgentsOn.value = (await f.readAsString()).trim() == 'chat' ? AgentView.chat : AgentView.terminal;
  } catch (_) {}
}

Future<void> setOpenAgentsOn(AgentView v) async {
  openAgentsOn.value = v;
  try {
    await (await openAgentsOnFile())?.writeAsString(v.name);
  } catch (_) {}
}

String openAgentsOnLabel(AgentView v) => v == AgentView.chat ? 'Chat' : 'Terminal';
