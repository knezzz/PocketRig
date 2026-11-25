import 'package:flutter/material.dart';

import '../../models.dart';
import '../kit.dart' show seatLabel;
import '../status_shape.dart';
import '../theme.dart';

/// The rig's agents under a chat or terminal header, as underline tabs: one
/// per seat with a session, each with its status shape and name. The seat on
/// screen is bold with an ink underline; the rest are muted. Scrolls sideways.
class SeatSwitcher extends StatelessWidget {
  const SeatSwitcher({super.key, required this.seats, required this.selected, required this.onTap});
  final List<Seat> seats;

  /// The logical id of the seat on screen.
  final String selected;
  final ValueChanged<Seat> onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      container: true,
      label: 'Seats in this rig',
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.divider))),
        child: SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final s in seats) _Tab(seat: s, on: s.logicalId == selected, onTap: () => onTap(s)),
          ]),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.seat, required this.on, required this.onTap});
  final Seat seat;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final state = seatLabel(seat);
    return Semantics(
      selected: on,
      // The current tab takes no tap, so it is not offered as a button.
      button: !on,
      label: '${seat.logicalId}, $state',
      onTap: on ? null : onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: on ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: on ? k.ink : Colors.transparent, width: 2)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            StatusShape(Status.of(seat.state), size: 8, semantics: false),
            const SizedBox(width: 7),
            Text(seat.logicalId,
                style: TextStyle(
                    fontSize: 13, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? k.ink : k.muted)),
          ]),
        ),
      ),
    );
  }
}
