import '../api/openrig_client.dart';
import '../models.dart';

enum HostKeyCheck { firstUse, matches, changed }

/// Trust on first use: no pin yet → accept and pin; same key → accept;
/// a different key → refuse until the user trusts it in Hosts.
HostKeyCheck checkHostKey(String? pinned, String seen) =>
    pinned == null ? HostKeyCheck.firstUse : (pinned == seen ? HostKeyCheck.matches : HostKeyCheck.changed);

/// Raised when a host presents a different SSH host key than the one pinned.
class HostKeyChangedException extends OpenRigException {
  HostKeyChangedException(this.host, this.seenType, this.seen)
      : super('The SSH host key of ${host.name} changed.\n'
            'Pinned: ${host.hostKeyFingerprint}\nNow:    $seen\n'
            'If you reinstalled or replaced the machine, open Hosts → ${host.name} and trust the new key. '
            'Otherwise, don\'t connect.');
  final Host host;
  final String seenType;
  final String seen;
}

/// Saves a host after its key was pinned on first use. Set by the app to
/// the host store's save.
Future<void> Function()? persistHostKeys;
