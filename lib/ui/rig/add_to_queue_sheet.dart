import 'package:flutter/material.dart';

import '../../api/openrig_client.dart';
import '../../main.dart';
import '../../models.dart';
import '../common.dart';
import '../theme.dart';
import '../kit.dart' show Segmented;

/// "Add to queue": puts a message on a seat's queue as a durable item (not typed into its terminal).
/// With [seat] the agent is chosen and only the message is asked; otherwise pick one of [seats].
/// Sends itself and stays open with the text on a failure; returns the agent's name once it is queued.
Future<String?> showAddToQueue(BuildContext context, {Seat? seat, List<Seat> seats = const []}) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AddToQueueSheet(seat: seat, seats: seats),
    );

class AddToQueueSheet extends StatefulWidget {
  const AddToQueueSheet({super.key, this.seat, this.seats = const []});
  final Seat? seat;
  final List<Seat> seats;
  @override
  State<AddToQueueSheet> createState() => _AddToQueueSheetState();
}

class _AddToQueueSheetState extends State<AddToQueueSheet> {
  static const _priorities = ['routine', 'urgent', 'critical'];
  late Seat? _seat = widget.seat;
  String _priority = _priorities.first;
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  /// What the last attempt sent, and the id it used: a retry of the same thing reuses it, so it can't add a second row
  /// even if the first attempt reached the daemon; changing anything mints a new one.
  String? _sentKey, _id;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = AppScope.clientOf(context);
    final seat = _seat;
    if (api == null || seat == null) return;
    final body = _text.text.trim();
    final key = '${seat.sessionName}|$_priority|$body';
    if (key != _sentKey) {
      _sentKey = key;
      _id = OpenRigClient.newQitemId();
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await api.queueCreate(id: _id!, destination: seat.sessionName!, body: body, priority: _priority);
      if (mounted) Navigator.pop(context, seat.logicalId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                widget.seat == null ? 'Add to queue' : 'Add to ${widget.seat!.logicalId}\'s queue',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (widget.seat == null) ...[
              DropdownButtonFormField<Seat>(
                initialValue: _seat,
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [for (final s in widget.seats) DropdownMenuItem(value: s, child: Text(s.logicalId))],
                onChanged: (v) => setState(() => _seat = v),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 8,
              autofocus: widget.seat != null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Message', hintText: 'What should it pick up?'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Segmented<String>(
              values: _priorities,
              labels: _priorities,
              selected: _priority,
              onChanged: (p) => setState(() => _priority = p),
              semanticLabel: 'Priority',
            ),
            if (_error != null) ErrorBanner(_error!, margin: const EdgeInsets.only(top: 12)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending || _seat == null || _text.text.trim().isEmpty ? null : _send,
              style: sheetAction,
              child: Text(_sending ? 'Adding…' : 'Add to queue'),
            ),
          ]),
        ),
      );
}

/// Seats that can take queued work: an agent with a session.
bool canQueue(Seat s) => s.isAgent && s.sessionName != null;
