import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:loggy/loggy.dart';

import '../api/openrig_client.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'chat_cache.dart';

/// The macOS build: this machine is a host too, reached without SSH.
/// Off under `flutter test`, which also runs on macOS; tests turn it on themselves.
bool isDesktop = !kIsWeb && Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST');

/// The macOS keychain options. The legacy keychain needs no signing team, so local macOS builds can save hosts. [service] is the
/// keychain service the items go under: the plugin's default for the app (saved hosts stay where they are). A build that must
/// never touch the real app's items (the design demo) sets [HostStore.keychainService] before it builds its store: macOS asks
/// the person for permission when an app reads another app's item.
@visibleForTesting
MacOsOptions hostStoreMacOptions({String? service}) =>
    MacOsOptions(useDataProtectionKeyChain: false, accountName: service ?? HostStore.keychainService);

/// Hosts, including their SSH keys, live in the platform keychain/keystore.
class HostStore extends ChangeNotifier {
  HostStore({FlutterSecureStorage? storage}) : _storage = storage ?? FlutterSecureStorage(mOptions: hostStoreMacOptions());

  final FlutterSecureStorage _storage;

  /// The keychain service the next [HostStore] (without a storage of its own) saves under.
  static String keychainService = AppleOptions.defaultAccountName;
  static const _key = 'pocketrig.hosts.v1';
  static const _activeKey = 'pocketrig.activeHost.v1';
  static const _sidebarKey = 'pocketrig.sidebarWidth.v1';

  /// The desktop sidebar's width the person dragged it to, kept across launches.
  double sidebarWidth = defaultSidebarWidth;
  static const defaultSidebarWidth = 264.0;

  /// Every saved host, on or off: what is saved, and what the Hosts screen lists.
  final List<Host> all = [];
  String? _activeId;

  /// The hosts that are on: what the rest of the app reads. An off host is in [all] only.
  List<Host> get hosts => [for (final h in all) if (h.enabled) h];

  /// The active host: always one that is on.
  Host? get active {
    final on = hosts;
    for (final h in on) {
      if (h.id == _activeId) return h;
    }
    return on.isEmpty ? null : on.first;
  }

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    all.clear();
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      all.addAll(list.cast<Map>().map((m) => Host.fromJson(m.cast())));
    }
    _activeId = await _storage.read(key: _activeKey);
    sidebarWidth = double.tryParse(await _storage.read(key: _sidebarKey) ?? '') ?? defaultSidebarWidth;
    if (isDesktop && !all.any((h) => h.isLocal)) {
      // This Mac always heads the list; saved hosts stay (a save writes the whole list back).
      all.insert(0, Host.local(Platform.environment['USER'] ?? ''));
      if (!all.any((h) => h.id == _activeId)) _activeId = Host.localId;
    }
    notifyListeners();
    for (final h in all) {
      unawaited(resolvePins(h));
    }
  }

  /// Keeps the sidebar's width (written when a drag ends).
  Future<void> setSidebarWidth(double w) async {
    sidebarWidth = w;
    await _storage.write(key: _sidebarKey, value: w.toString());
  }

  /// Persists in-place changes to a host (e.g. a newly pinned host key).
  Future<void> save() => _save();

  Future<void> _save() async {
    await _storage.write(key: _key, value: jsonEncode(all.map((h) => h.toJson()).toList()));
    if (_activeId != null) await _storage.write(key: _activeKey, value: _activeId);
    notifyListeners();
  }

  Future<void> upsert(Host host) async {
    final i = all.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      all[i] = host;
    } else {
      all.add(host);
    }
    _activeId ??= host.id;
    await _save();
  }

  static String _appKey(String hostId) => 'pocketrig.coreApp.$hostId.v1';

  /// The host's Core app credential `{credentialId, token, actor}`, or null. The token is a secret: it lives only here.
  Future<Map<String, String>?> appCredential(String hostId) async {
    try {
      final raw = await _storage.read(key: _appKey(hostId));
      return raw == null ? null : (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  Future<void> setAppCredential(String hostId, {required String credentialId, required String token, required String actor}) =>
      _storage.write(key: _appKey(hostId), value: jsonEncode({'credentialId': credentialId, 'token': token, 'actor': actor}));

  // One key per answer, so two answers saved together can't overwrite each other.
  static String _answerKey(String hostId, String requestId) => 'pocketrig.coreAnswer.$hostId.$requestId';

  /// An answer sent or about to be: `{answerId, payload}`. Saved before the POST so a lost response retries the same id
  /// and payload. No secrets in it.
  Future<Map<String, Object?>?> pendingAnswer(String hostId, String requestId) async {
    try {
      final raw = await _storage.read(key: _answerKey(hostId, requestId));
      return raw == null ? null : (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  Future<void> setPendingAnswer(String hostId, String requestId, Map<String, Object?>? entry) => entry == null
      ? _storage.delete(key: _answerKey(hostId, requestId))
      : _storage.write(key: _answerKey(hostId, requestId), value: jsonEncode(entry));

  /// Revokes [host]'s Core app credential (best effort) and deletes the token.
  Future<void> revokeAppCredential(Host host) async {
    final cred = await appCredential(host.id);
    if (cred != null) unawaited(OpenRigClient.create(host).revokeAppCredential(cred['credentialId']!));
    await dropAppCredential(host.id);
  }

  Future<void> dropAppCredential(String hostId) => _storage.delete(key: _appKey(hostId));

  Future<void> remove(String id) async {
    if (isDesktop && id == Host.localId) return;
    final host = all.where((h) => h.id == id).firstOrNull;
    if (host != null) await revokeAppCredential(host);
    try {
      for (final k in (await _storage.readAll()).keys.where((k) => k.startsWith('pocketrig.coreAnswer.$id.'))) {
        await _storage.delete(key: k);
      }
    } catch (_) {}
    all.removeWhere((h) => h.id == id);
    if (_activeId == id) _activeId = hosts.isEmpty ? null : hosts.first.id;
    await _save();
    await chatCache?.forgetHost(id).catchError((Object e) => logWarning('chat cache: $e'));
  }

  /// Turns [host] on or off. Everything it holds stays (key, pins, names, topic, kinds); only [hosts] and [active]
  /// change, so an off host vanishes from the app and turning it on again needs no pairing. This Mac stays on.
  Future<void> setEnabled(Host host, bool on) async {
    if (isDesktop && host.isLocal) return;
    host.enabled = on;
    if (!on) await revokeAppCredential(host);
    if (!on && _activeId == host.id) _activeId = hosts.firstOrNull?.id;
    await _save();
  }

  Future<void> select(String id) async {
    _activeId = id;
    await _save();
  }

  /// [path] as the host's absolute path: a pin must match the cwd its rigs report, or the pin and its rigs are two
  /// projects. A `~` path is resolved on the host; one that can't be reached keeps it as typed, for [resolvePins].
  Future<String> _absolute(Host host, String path) async {
    if (!path.startsWith('~')) return path;
    try {
      final abs = await SshExec.use(host, (s) => s.resolve(path)).timeout(const Duration(seconds: 8));
      return abs.startsWith('/') ? abs : path;
    } catch (_) {
      return path;
    }
  }

  /// Pins saved before they were resolved (`~/code/x`): made absolute once the host answers.
  Future<void> resolvePins(Host host) async {
    if (!host.pinnedFolders.any((p) => p.startsWith('~'))) return;
    final tilde = host.pinnedFolders.where((p) => p.startsWith('~')).toSet();
    final abs = {for (final p in tilde) p: await _absolute(host, p)};
    // Re-read after the awaits: a pin or unpin made meanwhile stays as it is.
    final resolved = <String>{for (final p in host.pinnedFolders) abs[p] ?? p}.toList();
    if (listEquals(resolved, host.pinnedFolders)) return;
    host.pinnedFolders = resolved;
    await _save();
  }

  Future<void> pinFolder(Host host, String path) async {
    final clean = await _absolute(host, path.trim());
    if (clean.isEmpty || host.pinnedFolders.contains(clean)) return;
    host.pinnedFolders.add(clean);
    await _save();
  }

  Future<void> unpinFolder(Host host, String path) async {
    host.pinnedFolders.remove(path);
    await _save();
  }
}
