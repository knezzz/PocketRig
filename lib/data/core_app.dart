import '../api/openrig_client.dart';
import '../models.dart';
import 'core_ask.dart';
import 'host_store.dart';

/// Where a host stands on answering structured questions (OpenRig 0.7.22's Core app job).
enum CoreAppState {
  /// An older daemon: nothing is shown and no credential is issued.
  unavailable,

  /// The daemon has the job but no person is registered to answer as.
  noPerson,

  /// A credential is stored: [CoreApp.token] and [CoreApp.actor] are set.
  ready,

  /// A credential couldn't be issued; [CoreApp.reason] says why.
  failed,
}

class CoreApp {
  const CoreApp(this.state, {this.actor, this.token, this.reason});
  final CoreAppState state;
  final String? actor;
  final String? token;
  final String? reason;
}

/// The exact command that registers a person, for the "no person" hint.
const registerPersonCommand = 'rig gateway human add <id> --display-name "<Name>" --delivery-class B --default';

final _reissued = <String>{};

/// Forgets which hosts already re-issued this session (tests).
void resetCoreAppSession() => _reissued.clear();

/// The host's Core app session: checks the job exists, then reuses the stored credential or issues one for the host's
/// default person (once per host). [forceNew] drops the stored credential first (a 401/403 from an app call).
Future<CoreApp> coreAppFor(HostStore store, Host host, {bool forceNew = false}) async {
  final api = OpenRigClient.create(host);
  try {
    if (!await api.coreAppAvailable()) return const CoreApp(CoreAppState.unavailable);
    if (forceNew) {
      // Once per session: a daemon that keeps refusing a fresh credential must not get a new one every refresh.
      if (!_reissued.add(host.id)) return const CoreApp(CoreAppState.failed, reason: 'The daemon refused the credential.');
      await store.revokeAppCredential(host);
    }
    final have = await store.appCredential(host.id);
    if (have != null && have['token'] != null && have['actor'] != null) {
      return CoreApp(CoreAppState.ready, actor: have['actor'], token: have['token']);
    }
    final actor = await api.defaultPerson();
    if (actor == null) return const CoreApp(CoreAppState.noPerson);
    final c = await api.issueAppCredential(actor);
    await store.setAppCredential(host.id, credentialId: c.credentialId, token: c.token, actor: actor);
    return CoreApp(CoreAppState.ready, actor: actor, token: c.token);
  } catch (e) {
    return CoreApp(CoreAppState.failed, reason: e is OpenRigException ? e.message : '$e');
  }
}

/// The host's session and its structured asks. A 401/403 from the read drops the credential and issues one more, once.
Future<(CoreApp, List<CoreAsk>)> loadCoreAsks(HostStore store, Host host) async {
  var app = await coreAppFor(store, host);
  for (var attempt = 0; app.state == CoreAppState.ready; attempt++) {
    try {
      final rows = await OpenRigClient.create(host).appNeedsMe(app.token!, app.actor!);
      // The token stays in secure storage: what the screen keeps is the state and the actor.
      return (CoreApp(CoreAppState.ready, actor: app.actor), [for (final r in rows) if (CoreAsk.fromJson(r) case final a?) a]);
    } on OpenRigException catch (e) {
      if (attempt == 0 && (e.status == 401 || e.status == 403)) {
        app = await coreAppFor(store, host, forceNew: true);
        continue;
      }
      return (CoreApp(CoreAppState.failed, reason: e.message), const <CoreAsk>[]);
    }
  }
  return (CoreApp(app.state, actor: app.actor, reason: app.reason), const <CoreAsk>[]);
}
