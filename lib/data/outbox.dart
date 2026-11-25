import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/openrig_client.dart';

/// A chat message on its way out. [failed] once every attempt has failed.
class OutMessage {
  OutMessage(this.text, {this.failed = false}) : id = '${DateTime.now().microsecondsSinceEpoch}';
  final String id;
  final String text;
  int attempts = 0;
  bool failed;
  String? error;
  Timer? _retry;
}

/// Messages that haven't reached their agent yet, per chat, kept on disk so
/// leaving the chat or closing the app doesn't lose them. Retries carry on
/// after the chat closes, while the app runs.
class Outbox extends ChangeNotifier {
  Outbox({this.file, this.delays = const [Duration(seconds: 2), Duration(seconds: 6)]});
  static const maxAttempts = 3;

  /// Null keeps it in memory only (tests).
  final File? file;

  /// Wait before attempt 2, 3, ...
  final List<Duration> delays;
  final _chats = <String, List<OutMessage>>{};

  static Future<Outbox> open() async =>
      Outbox(file: File('${(await getApplicationSupportDirectory()).path}/outbox.json'))..load();

  List<OutMessage> of(String chat) => _chats[chat] ?? const [];

  /// Queues [text] and tries [deliver] up to [maxAttempts] times.
  void send(String chat, String text, Future<void> Function() deliver) {
    final m = OutMessage(text);
    (_chats[chat] ??= []).add(m);
    _save();
    _attempt(chat, m, deliver);
  }

  /// Another [maxAttempts] tries for a message that failed.
  void retry(String chat, OutMessage m, Future<void> Function() deliver) {
    m
      ..failed = false
      ..attempts = 0
      ..error = null;
    _attempt(chat, m, deliver);
  }

  void remove(String chat, OutMessage m) {
    m._retry?.cancel();
    final list = _chats[chat];
    if (list == null || !list.remove(m)) return;
    if (list.isEmpty) _chats.remove(chat);
    _save();
    notifyListeners();
  }

  Future<void> _attempt(String chat, OutMessage m, Future<void> Function() deliver) async {
    m.attempts++;
    notifyListeners();
    try {
      await deliver();
      remove(chat, m);
    } catch (e) {
      if (!of(chat).contains(m)) return; // deleted while it was trying
      m.error = e.toString();
      // It may have been typed already: trying again could deliver it twice.
      final maybeSent = e is OpenRigException && e.maybeSent;
      if (maybeSent) m.error = 'It may have arrived; check the chat before you retry. ($e)';
      if (maybeSent || m.attempts >= maxAttempts) {
        m.failed = true;
        _save();
        notifyListeners();
      } else {
        m._retry = Timer(delays[(m.attempts - 1).clamp(0, delays.length - 1)], () => _attempt(chat, m, deliver));
        notifyListeners();
      }
    }
  }

  void load() {
    try {
      final f = file;
      if (f == null || !f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      // The app stopped before these got through: no sender left, so they wait for Retry.
      data.forEach((chat, texts) => _chats[chat] = [for (final t in texts as List) OutMessage(t as String, failed: true)]);
    } catch (e) {
      debugPrint('outbox: $e');
    }
  }

  void _save() {
    final f = file;
    if (f == null) return;
    final json = jsonEncode({for (final e in _chats.entries) e.key: [for (final m in e.value) m.text]});
    // One write at a time, so an older snapshot never lands last.
    _saving = _saving.then((_) => f.writeAsString(json)).catchError((Object e) {
      debugPrint('outbox: $e');
      return f;
    });
  }

  Future<Object?> _saving = Future.value();
}

/// Set in main. Tests that send get an in-memory one.
Outbox outbox = Outbox();
