import '../api/openrig_client.dart';
import '../models.dart';
import '../terminal/transport.dart';

/// Types [text] into [seat]'s session and presses Enter: the one send for every screen that writes to an agent (the chat, a
/// drawing). A rig seat goes through the daemon ([api]); a loose agent (no rig) has no daemon route, so it is typed into its
/// own tmux pane over SSH with the same exact-target, checked send as an answer ([pressSeatKeys]). It throws when the text
/// could not be sent (no session, no route, no tmux), so a caller never says "Sent" for nothing.
Future<void> sendToSeat(Host? host, OpenRigClient? api, Seat seat, String text) async {
  final session = seat.sessionName;
  if (session == null) throw OpenRigException('${seat.logicalId} has no session to send to.');
  if (seat.rigId.isEmpty) {
    if (host == null) throw OpenRigException('No host to send to ${seat.logicalId}.');
    await pressSeatKeys(host, seat, [TypedAnswer(text)]);
  } else {
    if (api == null) throw OpenRigException('Not connected to a daemon for ${seat.logicalId}.');
    await api.send(session, text);
  }
}
