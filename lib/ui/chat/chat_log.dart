part of '../chat_screen.dart';

// C
extension _ChatLog on _ChatPageState {
  /// Reads the pane while the agent works. The text goes away when the agent stops, and when the
  /// transcript already holds it (the log gets a block when it is complete; the pane still shows it).
  Future<void> _pollPane() async {
    final host = AppScope.read(context).active;
    final working = _seat.state == SeatState.working && !_seat.needsInput;
    if (_paneBusy || host == null || !working || !widget.active || !windowActive.value || !_seat.isClaude) {
      if (_preview != null && !working && mounted) _set(() => _preview = null);
      return;
    }
    _paneBusy = true;
    try {
      final pane = await readPane(host, _seat);
      var text = pane == null ? null : parsePanePreview(pane);
      if (text != null && _inTranscript(text)) text = null;
      if (mounted && widget.active && text != _preview) _set(() => _preview = text);
    } catch (_) {
      if (mounted && _preview != null) _set(() => _preview = null);
    } finally {
      _paneBusy = false;
    }
  }

  /// A recent assistant message that already says [preview] (its start, as the pane reflows long lines).
  bool _inTranscript(String preview) {
    final p = _ChatPageState._flat(preview);
    final head = p.length > 80 ? p.substring(0, 80) : p;
    final items = _transcript.items;
    for (var i = items.length - 1; i >= 0 && i >= items.length - 6; i--) {
      if (items[i] case AssistantMessage(:final text) when _ChatPageState._flat(text).contains(head)) return true;
    }
    return false;
  }

  Future<void> _open() async {
    final host = AppScope.read(context).active;
    if (host == null) return;
    _hostId = host.id;
    final claim = openKey(host.id, _key);
    if (_claimed != claim) {
      // _open runs again on every retry: hold the chat once per screen.
      if (_claimed case final old?) openChatKeys.remove(old);
      openChatKeys.add(_claimed = claim);
    }
    _reconnect?.cancel();
    _reconnect = null;
    _set(() {
      _locating = _transcript.items.isEmpty && !_starting;
      _error = null;
    });
    await _showCached(host.id);
    if (!mounted) return;
    try {
      final path = await locateSessionLog(host, _seat, exactOnly: widget.waitForLog);
      if (!mounted) return;
      final cached = _cached;
      final same = cached != null && cached.path == path && cached.offset > 0 && cached.lines.isNotEmpty;
      // A seed is only the last stretch of the log: it paints the first frame, then the full read replaces it.
      final seeded = same && cached.seeded;
      final resume = same && !seeded;
      _hold.clear();
      _fresh = ChatTranscript(sidechain: _subagent);
      _freshSaved.clear();
      _freshBytes = 0;
      _cutHistory = false;
      _droppedIndex = null;
      _generation++; // a batch still decoding for the old read must not land in the new one
      _seedOffset = seeded ? cached.offset : null;
      if (!resume && !seeded) _startOver();
      if (path == null) {
        // A new session writes its log with its first message. Look again
        // every few seconds, for a while: a Try again starts that over.
        final since = _startingSince ??= DateTime.now();
        if (widget.waitForLog && DateTime.now().difference(since) < _ChatPageState._startingPatience) {
          _set(() {
            _locating = false;
            _starting = true;
          });
          _reconnect = Timer(_ChatPageState._startingPoll, _open);
          return;
        }
        _set(() {
          _locating = false;
          _starting = false;
          _startingSince = null;
          _error = widget.waitForLog
              ? '${_seat.logicalId} hasn\'t written a session log yet. It may be asking something in its terminal.'
              : 'No Claude Code session log found for ${_seat.logicalId}'
                  '${_seat.cwd != null ? ' (looked in ~/.claude/projects for ${_seat.cwd})' : ''}.';
        });
        return;
      }
      _starting = false;
      _wantCache = chatCache != null && _seat.state != SeatState.stopped && !_subagent;
      _caching = _wantCache && !seeded;
      if (!resume && !seeded) await _restartCache(path);
      _savedOffset = resume ? cached.offset : 0;
      if (!mounted) return;
      final tail = SessionLogTail.create(host, path);
      if (resume) tail.resumeFrom(cached.offset, truncated: cached.truncated);
      tail.onRewound = () {
        if (!mounted) return;
        _set(_startOver);
        _restartCache(path);
      };
      _subs.add(tail.lines.listen(_onLine));
      _subs.add(tail.status.listen((s) {
        if (mounted) _set(() => _status = s);
      }));
      _set(() {
        _logPath = path;
        _tail = tail;
        _locating = false;
      });
      await tail.start();
    } catch (e) {
      if (!mounted) return;
      if (_transcript.items.isNotEmpty) {
        // Keep showing what's saved and try again quietly.
        _set(() {
          _locating = false;
          _status = 'offline, showing saved chat';
        });
        _reconnect = Timer(const Duration(seconds: 10), _open);
        return;
      }
      _set(() {
        _locating = false;
        _error = 'Couldn\'t open the session log over SSH: $e';
      });
    }
  }

  /// Fills the screen from the cache, the first time through. Only a
  /// convenience, so a broken cache just means the slow path.
  Future<void> _showCached(String hostId) async {
    final cache = chatCache;
    if (_cacheChecked || cache == null) return;
    _cacheChecked = true;
    try {
      final c = await cache.load(hostId, _key);
      if (c == null || !mounted) return;
      _cached = c;
      if (c.lines.isEmpty) return;
      final decoded = await _ChatPageState._decode(c.lines);
      if (!mounted) return;
      _set(() {
        for (final d in decoded) {
          _transcript.addDecoded(d);
        }
        _seenTools = _transcript.items.whereType<ToolCall>().where((t) => t.done).length;
        _locating = false;
      });
    } catch (e) {
      logWarning('chat cache: $e');
    }
  }

  /// What's on screen isn't this log (a new session, or a rewritten file).
  void _startOver() {
    _generation++;
    _inbox.clear();
    _hold.clear();
    _fresh = ChatTranscript(sidechain: _subagent);
    _freshSaved.clear();
    _freshBytes = 0;
    _cutHistory = false;
    _droppedIndex = null;
    _cached = null;
    _transcript = ChatTranscript(sidechain: _subagent);
    _unsaved.clear();
    _seenTools = 0;
  }

  Future<void> _restartCache(String path) async {
    if (!_caching) return;
    try {
      await chatCache!.restart(_hostId!, _key, path);
    } catch (e) {
      _caching = false;
      logWarning('chat cache: $e');
    }
  }

  /// Saves what was read since the last call. Writes run in order, slimmed off
  /// the UI thread, since the first read of a log can be 25 MB.
  void _saveNow() {
    _save?.cancel();
    _save = null;
    final tail = _tail, cache = chatCache, hostId = _hostId;
    if (!_caching || tail == null || cache == null || hostId == null) return;
    // The tail's offset already counts lines still being decoded: save after them.
    if (_draining && mounted) {
      _save = Timer(const Duration(seconds: 1), _saveNow);
      return;
    }
    final path = _logPath;
    if (path == null) return;
    final lines = List.of(_unsaved);
    _unsaved.clear();
    final earlier = _droppedIndex;
    _droppedIndex = null;
    final from = _savedOffset, offset = tail.committedOffset, truncated = tail.truncated || _cutHistory, key = _key;
    _savedOffset = offset;
    _saving = _saving.then((_) async {
      if (!await cache.append(hostId, key, path, from, offset, truncated, lines, earlier: earlier)) _caching = false;
    }).catchError((Object e) {
      _caching = false;
      logWarning('chat cache: $e');
    });
  }

  void _onLine(String line) {
    if (_seedOffset != null) {
      _hold.add(line);
      if (!_freshBusy) _decodeFresh();
      _swapCheck ??= Timer(Duration.zero, _swapSeed); // after the rest of this chunk
      return;
    }
    _inbox.add(line);
    if (!_draining) _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    await Future<void>.delayed(Duration.zero); // let a burst arrive as one batch
    while (_inbox.isNotEmpty && mounted) {
      final batch = List.of(_inbox), generation = _generation;
      _inbox.clear();
      final decoded = await _ChatPageState._decode(batch);
      if (!mounted || generation != _generation) continue;
      var changed = false;
      for (var i = 0; i < batch.length; i++) {
        final c = _transcript.addDecoded(decoded[i]);
        // Lines the chat ignores aren't kept, but the offset still moves past them.
        if (c && _caching) _unsaved.add(batch[i]);
        changed |= c;
      }
      if (_caching) _save ??= Timer(const Duration(seconds: 1), _saveNow);
      if (changed) _repaintSoon();
    }
    _draining = false;
  }

  /// Once the read has passed the seed, shows it in place of the seed. Not while a finger or fling is moving the page.
  Future<void> _swapSeed([int? stalledAt]) async {
    _swapCheck = null;
    final seed = _seedOffset, tail = _tail, path = _logPath;
    if (seed == null || tail == null || path == null || !mounted) return;
    if (tail.committedOffset < seed && (tail.committedOffset != stalledAt || _status != 'live')) {
      // A log rewritten shorter than the seed never reaches it: swap once the read has gone quiet and the tail is live (not reconnecting).
      final at = _status == 'live' ? tail.committedOffset : null; // a stall counts only if the tail was live when the wait began
      _swapCheck = Timer(const Duration(seconds: 5), () => _swapSeed(at));
      return;
    }
    if (_scroll.hasClients && _scroll.position.isScrollingNotifier.value) {
      _swapCheck = Timer(const Duration(milliseconds: 300), _swapSeed);
      return;
    }
    if (_freshBusy || _hold.isNotEmpty) {
      _swapCheck = Timer(const Duration(milliseconds: 50), _swapSeed); // still decoding
      return;
    }
    final fresh = _fresh, saved = List.of(_freshSaved);
    if (_scroll.hasClients && _scroll.position.pixels > 24) _anchor = _rowOnScreen();
    _set(() {
      _transcript = fresh;
      _unsaved
        ..clear()
        ..addAll(saved);
      _seenTools = fresh.items.whereType<ToolCall>().where((t) => t.done).length;
      _seedOffset = null;
      _cached = null;
    });
    _freshSaved.clear();
    _freshBytes = 0;
    _caching = _wantCache;
    _savedOffset = 0;
    await _restartCache(path);
    _saveNow();
  }

  Future<void> _decodeFresh() async {
    _freshBusy = true;
    await Future<void>.delayed(Duration.zero); // let a burst arrive as one batch
    while (_hold.isNotEmpty && mounted) {
      final batch = List.of(_hold), generation = _generation;
      _hold.clear();
      final decoded = await _ChatPageState._decode(batch);
      if (!mounted || generation != _generation) continue;
      for (var i = 0; i < batch.length; i++) {
        if (!_fresh.addDecoded(decoded[i])) continue;
        _freshSaved.add(batch[i]);
        _freshBytes += batch[i].length;
      }
      if (_freshBytes > chatFreshCap * 3 ~/ 2) await _cutFresh(generation);
    }
    _freshBusy = false;
  }

  Future<void> _cutFresh(int generation) async {
    var cut = 0;
    while (_freshBytes > chatFreshCap && cut < _freshSaved.length) {
      _freshBytes -= _freshSaved[cut++].length;
    }
    final dropped = _freshSaved.sublist(0, cut);
    _freshSaved.removeRange(0, cut);
    _cutHistory = true;
    // The dropped lines' media still belongs in the rig's list: keep its index, not the lines.
    final index = await compute(indexLogLines, dropped);
    if (mounted && generation == _generation) {
      _droppedIndex = _droppedIndex == null ? index : mergeLogIndex(_droppedIndex!, index);
    }
  }

  void _repaintSoon() {
    // Repaint at most every 120 ms while the history streams in.
    _flush ??= Timer(const Duration(milliseconds: 120), () {
      _flush = null;
      if (!mounted) return;
      if (_scroll.hasClients && _scroll.position.pixels > 24) _anchor = _rowOnScreen();
      _set(() {
        final users = _transcript.items.whereType<UserMessage>().toList();
        final recent = users.length > 5 ? users.sublist(users.length - 5) : users;
        _pending.removeWhere((p) {
          final echo = recent.where((u) => u.text.contains(p));
          // The echo replaces the pending bubble in place: no second entrance.
          _appeared.addAll(echo.map((u) => u.key));
          return echo.isNotEmpty;
        });
        // A new call is asking (or the answered one finished): the last answer is spent.
        // The answered call finishing means the keys landed, even while the press is still winding down.
        if (_decision != null && (!_pressing || !_callUnfinished(_decisionFor)) && _permissionCall()?.id != _decisionFor) {
          _decision = null;
        }
      });
      // A finished edit or command may have changed the checkout.
      final tools = _transcript.items.whereType<ToolCall>().where((c) => c.done).length;
      if (tools != _seenTools) {
        _seenTools = tools;
        _gitSoon?.cancel();
        _gitSoon = Timer(const Duration(seconds: 3), _loadGit);
      }
    });
  }

  /// The newest call still waiting for its result: running, or asking.
  /// Walks back from the end: runs on every build.
  ToolCall? _waitingCall() {
    final items = _transcript.items;
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i] case final ToolCall c) return c.done ? null : c;
    }
    return null;
  }

  /// The call whose permission the terminal is asking now. Claude Code asks parallel calls oldest first, so
  /// it is the oldest unfinished call of the trailing run of tool calls (the working line uses the newest,
  /// [_waitingCall]). Null when the daemon's reason names another tool: then the seat's own words describe it.
  ToolCall? _permissionCall() {
    final items = _transcript.items;
    ToolCall? oldest;
    for (var i = items.length - 1; i >= 0 && items[i] is ToolCall; i--) {
      final c = items[i] as ToolCall;
      if (!c.done) oldest = c;
    }
    final said = _seat.needsInputReason?.split(':').first.trim();
    // A reason still worded as the ask just answered is stale: the log is the better witness then.
    final stale = _decisionSig != null && _decisionSig == askSig(_seat);
    // Only a tool's name compares (Bash, Edit, mcp__x); a code like permission_prompt says nothing about the call.
    if (!stale && oldest != null && said != null && RegExp(r'^([A-Z][A-Za-z]*|mcp__\S+)$').hasMatch(said) && said != oldest.name) {
      return null;
    }
    return oldest;
  }

  /// An agent outside a rig has no daemon seat: its state is what the
  /// watcher's hook last wrote on the host.
  Future<void> _pollLoose() async {
    final host = AppScope.read(context).active, agent = widget.loose;
    if (host == null || agent == null || _pollingLoose) return;
    _pollingLoose = true;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      final hooks = parseHookFile(await ssh.run('cat $looseFile 2>/dev/null'));
      final h = hooks
          .where((h) => h.id == agent.id || (h.claudeSessionId != null && h.claudeSessionId == agent.claudeSessionId))
          .firstOrNull;
      if (!mounted || h == null) return;
      final fresh = agent.mergeHook(h)..label = agent.label;
      _set(() {
        _seat = fresh.toSeat();
        if (_waitingCall()?.name != 'AskUserQuestion') _settleDecision(_seat);
        if (!_seat.needsInput && _waitingCall()?.name != 'AskUserQuestion') _decision = null;
      });
    } catch (_) {/* keeps the last state */} finally {
      ssh?.close();
      _pollingLoose = false;
    }
  }

  Future<void> _pollSeat() async {
    if (widget.loose != null) return _pollLoose();
    final api = AppScope.clientOf(context);
    if (api == null || _seat.rigId.isEmpty) return;
    try {
      final polled = await pollSeat(api, _seat);
      if (!mounted || polled == null) return;
      final (fresh, agents) = polled;
      _set(() {
        _settleDecision(fresh);
        _seat = fresh;
        _rigSeats = agents;
      });
    } catch (_) {}
  }

  /// The folder's git status and the processes the agent started.
  Future<void> _loadGit() async {
    final host = AppScope.read(context).active;
    final cwd = _seat.cwd ?? _transcript.cwd;
    final session = _seat.sessionName;
    if (host == null || (cwd == null && session == null)) return;
    SshExec? ssh;
    try {
      ssh = await SshExec.connect(host);
      if (cwd != null) {
        try {
          final g = await ssh.gitStatus(cwd);
          fleet.feedFor(host).prs[cwd] = g.pr; // Shown in the Active tab.
          if (mounted) _set(() => _git = g);
        } catch (_) {/* the git bar just stays hidden */}
      }
      if (session != null) {
        try {
          final jobs = await ssh.agentJobs(session);
          if (mounted) _set(() => _jobs = jobs);
        } catch (_) {/* the jobs bar just stays hidden */}
      }
      // PRs this session opened: their name and size, once each.
      for (final u in _transcript.openedPrs.where((u) => !_prInfo.containsKey(u.toString()))) {
        try {
          if (await ssh.pullRequest(u) case final pr?) {
            if (mounted) _set(() => _prInfo[u.toString()] = pr);
          }
        } catch (_) {/* stays "owner/repo #n" */}
      }
      final id = _logPath?.split('/').last.replaceFirst(RegExp(r'\.jsonl$'), '') ?? claudeSessionOf(_seat);
      if (id != null) {
        final subs = (await ssh.subagents()).where((s) => s.sessionId == id).toList();
        if (mounted) _set(() => _subagents = subs);
      }
    } catch (_) {/* the bars just stay hidden */} finally {
      ssh?.close();
    }
  }
}
