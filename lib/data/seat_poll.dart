import '../api/openrig_client.dart';
import '../models.dart';
import 'fleet.dart';

/// How often a screen that watches a seat or a launching rig refreshes it.
const seatPollEvery = Duration(seconds: 3);

/// How often the open chat reads its agent's pane for the reply being written.
const panePreviewEvery = Duration(seconds: 1);

/// [seat] as the daemon shows it now, with its rig's agent seats; null when the rig no longer lists it.
/// With [host], each seat is marked with the shells and monitors it waits on (its on-shell state).
Future<(Seat, List<Seat>)?> pollSeat(OpenRigClient api, Seat seat, [Host? host]) async {
  final seats = await api.seats(seat.rigId);
  if (host != null) fleet.feedFor(host).applyShells(seats);
  final fresh = seats.where((s) => s.logicalId == seat.logicalId).firstOrNull;
  if (fresh == null) return null;
  return (fresh, seats.where((s) => s.isAgent && s.sessionName != null).toList());
}
