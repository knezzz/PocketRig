part of '../chat_screen.dart';

// C
extension _ChatSend on _ChatPageState {
  /// Queues the message: it's kept and retried until it's sent or deleted.
  Future<void> _send() async {
    final text = _msg.text.trim();
    if (text.isEmpty) return;
    // A question or dialog open on the seat would take this message as its answer: ask first (the answer card is above).
    final host = AppScope.read(context).active;
    if (host != null && await askBeforeSending(context, host, _seat, inChat: true) != SendGuard.send) return;
    if (!mounted) return;
    final deliver = _deliverer(text);
    if (deliver == null) return;
    _msg.clear();
    outbox.send(_outKey, text, deliver);
  }

  void _retry(OutMessage m) {
    if (_deliverer(m.text) case final deliver?) outbox.retry(_outKey, m, deliver);
  }

  /// Sends [text] without this screen's context, so retries outlive it. Once
  /// through, the text waits for its echo in the log as a pending bubble.
  Future<void> Function()? _deliverer(String text) {
    final api = AppScope.clientOf(context);
    final host = AppScope.read(context).active;
    final seat = _seat;
    if (seat.sessionName == null) return null;
    return () async {
      await sendToSeat(host, api, seat, text);
      if (mounted) _set(() => _pending.add(text));
    };
  }

  /// Types [text] into the session and presses Enter. False when it failed (toasted).
  Future<bool> _deliver(String text) async {
    final api = AppScope.clientOf(context);
    if (_seat.sessionName == null) return false;
    final host0 = AppScope.read(context).active;
    if (host0 != null && await askBeforeSending(context, host0, _seat, inChat: true) != SendGuard.send) return false;
    if (!mounted) return false;
    _set(() => _sending = true);
    try {
      await sendToSeat(AppScope.read(context).active, api, _seat, text);
      return true;
    } catch (e) {
      if (mounted) toast(context, e.toString());
      return false;
    } finally {
      if (mounted) _set(() => _sending = false);
    }
  }

  /// Switches the running session's model with Claude Code's `/model`.
  Future<void> _pickModel() async {
    final current = _pickedModel ?? _transcript.model ?? _seat.model;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => OptionSheet(
        title: 'Model',
        note: 'Switches this session with /model. The conversation carries on.',
        options: claudeModels,
        current: current == null ? 'default' : _ChatPageState._modelAlias(current),
      ),
    );
    if (picked == null || !mounted) return;
    if (await _deliver('/model $picked')) {
      if (!mounted) return;
      _set(() => _pickedModel = picked);
      toast(context, 'Model: ${claudeModels.firstWhere((o) => o.$1 == picked).$2}');
    }
  }

  /// Sets how hard the session thinks, with Claude Code's `/effort`.
  Future<void> _pickEffort() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => OptionSheet(
        title: 'Effort',
        note: 'How long Claude thinks before answering. Sent to this session as /effort.',
        options: claudeEfforts,
        current: _pickedEffort ?? _seat.effort ?? 'auto',
      ),
    );
    if (picked == null || !mounted) return;
    if (await _deliver('/effort $picked')) {
      if (!mounted) return;
      _set(() => _pickedEffort = picked);
      toast(context, 'Effort: ${claudeEfforts.firstWhere((o) => o.$1 == picked).$2}');
    }
  }

  /// Picks photos or files, copies them to the host, and adds their paths to
  /// the message, where the agent reads them.
  Future<void> _attach() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    final type = await showModalBottomSheet<FileType>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          OptionRow(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photos'),
              onTap: () => Navigator.of(ctx).pop(FileType.image)),
          OptionRow(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Files'),
              onTap: () => Navigator.of(ctx).pop(FileType.any)),
        ]),
      ),
    );
    if (type == null) return;
    final picked = await FilePicker.pickFiles(type: type, allowMultiple: true, withData: true);
    final files = [for (final f in picked?.files ?? <PlatformFile>[]) if (f.bytes != null) (f.name, f.bytes!)];
    if (files.isEmpty || !mounted) return;
    _set(() => _sending = true);
    try {
      final paths = await uploadAttachments(host, files);
      final text = _msg.text.trimRight();
      _msg.text = '${text.isEmpty ? '' : '$text '}${paths.join(' ')} ';
      _msg.selection = TextSelection.collapsed(offset: _msg.text.length);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send the file: $e');
    } finally {
      if (mounted) _set(() => _sending = false);
    }
  }

  /// Opens the session in the Claude app or claude.ai, where Remote Control
  /// gives the full chat, when `/remote-control` was run in it.
  Future<void> _openInClaude() => openInClaude(context, _seat);

  Future<bool> _answer(SeatAnswer a, String label) => _press([a.tmuxKey], label);

  /// Answers the seat's menu with [keys], showing [label] in its place. True only when the host confirmed the keys.
  Future<bool> _press(List<String> keys, String label) => _pressSteps(keys, label);

  /// Like [_press], where a step may also be words typed into the menu
  /// ([TypedAnswer]): the keys before it go first, then the text and Enter. True only when the host confirmed them: a failed
  /// answer and one that may have arrived are both false, and what follows an answer (a note, a switch to Auto) must wait for true.
  Future<bool> _pressSteps(List<Object> steps, String label) async {
    final host = AppScope.read(context).active;
    if (host == null || _pressing) return false;
    final asked = askSig(_seat);
    _pressing = true;
    _set(() {
      _decision = label;
      _decisionFor = _permissionCall()?.id;
      _decisionSig = asked;
      _decisionAt = DateTime.now();
    });
    try {
      await pressSeatKeys(host, _seat, steps);
      _decisionAt = DateTime.now(); // the settle time runs from the last key, not the tap
      needsYouAlerts.answered(_seat);
      // Look for the next ask without waiting for the 3 s poll.
      for (final d in [const Duration(milliseconds: 1500), answerSettle + const Duration(milliseconds: 200)]) {
        Future<void>.delayed(d, () => mounted ? _pollSeat() : null);
      }
      return true;
    } catch (e) {
      if (mounted) {
        if (e is OpenRigException && e.maybeSent) {
          // The keys may have been typed: the card stays resolved, so a second tap can't press them again into the next
          // question or the prompt. The next poll decides whether the ask is still open (it brings the card back if so).
          _decisionAt = DateTime.now(); // the settle time runs from here, not from the tap
          _set(() => _decision = 'May have arrived: check the terminal');
          toast(context, 'Not confirmed: ${e.message}');
          for (final d in [const Duration(milliseconds: 1500), answerSettle + const Duration(milliseconds: 200)]) {
            Future<void>.delayed(d, () => mounted ? _pollSeat() : null);
          }
        } else {
          // Nothing was typed: the card comes back to be tried again.
          _set(() => _decision = null);
          toast(context, 'Couldn\'t answer: $e');
        }
      }
    } finally {
      _pressing = false;
    }
    return false;
  }

  /// Allows this call, switches the live conversation to Auto with
  /// Shift+Tab, and saves Auto for the seat's next launch.
  Future<void> _allowAndAuto() async {
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null) return;
    if (!await _answer(SeatAnswer.allowOnce, 'Allowed once · switching to Auto')) return; // failed or unconfirmed: said so
    await Future<void>.delayed(const Duration(milliseconds: 500)); // let the menu close
    try {
      await switchSeatToAuto(host, _seat);
      await api.setPermissionMode(_seat, PermissionMode.auto);
      if (!mounted) return;
      _set(() {
        _mode = PermissionMode.auto.wire;
        _decision = 'Allowed once · now in Auto';
      });
    } catch (e) {
      if (mounted) {
        _set(() => _decision = 'Allowed once · not switched to Auto');
        toast(context, 'Couldn\'t switch to Auto: $e');
      }
    }
  }

  /// Denies, then sends the seat a note on what to do instead (queued like any message).
  Future<void> _denyWithNote() async {
    if (!await _answer(SeatAnswer.deny, 'Denied — ${_seat.logicalId} is waiting for instructions') || !mounted) return;
    final note = await inputSheet(context,
        title: 'Tell ${_seat.logicalId} what to do instead', action: 'Send', cancel: 'Skip', lines: 2);
    final text = note?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    if (_deliverer(text) case final deliver?) outbox.send(_outKey, text, deliver);
  }

  /// The permission sheet for the composer's mode pill; reads the mode back after.
  Future<void> _openPermissions() async {
    await showPermissionSheet(context, _seat);
    if (mounted) await _loadMode();
  }

  /// The terminal takes the chat's place (not a page over it): Back leaves the agent.
  void _toTerminal() => switchAgentView(
        context,
        (_) => TerminalScreen(target: SeatTarget(widget.rigName, _seat)),
        session: widget.seat.sessionName,
      );

  Future<void> _fetchFull(ToolCall c) async {
    final host = AppScope.read(context).active, path = _logPath;
    if (host == null || path == null) return;
    final full = await fetchToolCall(host, path, c.id);
    if (full == null) return;
    c
      ..input = full.input
      ..result = full.result ?? c.result
      ..isError = full.isError
      ..fullLines = null
      ..clipped = false;
  }
}
