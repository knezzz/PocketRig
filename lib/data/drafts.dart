import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Text typed in an agent's chat box and not sent, per chat (host + session), kept on disk next to the outbox so it
/// comes back after leaving the chat or restarting the app. Empty text removes the entry.
class Drafts {
  Drafts({this.file});

  /// Null keeps it in memory only (tests).
  final File? file;
  final _text = <String, String>{};

  static Future<Drafts> open() async => Drafts(
      file:
          File('${(await getApplicationSupportDirectory()).path}/drafts.json'))
    ..load();

  String of(String chat) => _text[chat] ?? '';

  void set(String chat, String text) {
    if (text.isEmpty ? _text.remove(chat) == null : _text[chat] == text) return;
    if (text.isNotEmpty) _text[chat] = text;
    _save();
  }

  void load() {
    try {
      final f = file;
      if (f == null || !f.existsSync()) return;
      (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)
          .forEach((k, v) => _text[k] = v as String);
    } catch (e) {
      debugPrint('drafts: $e');
    }
  }

  // Small and synchronous, so the last keystroke is on disk before the app can be killed.
  void _save() {
    try {
      final f = file;
      if (f == null) return;
      // Written aside and renamed over, so a kill mid-write can't leave half a file.
      final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(_text));
      tmp.renameSync(f.path);
    } catch (e) {
      debugPrint('drafts: $e');
    }
  }
}

/// Set in main. Tests get an in-memory one.
Drafts drafts = Drafts();
