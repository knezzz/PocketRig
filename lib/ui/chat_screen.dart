import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/openrig_client.dart' show OpenRigException;
import '../data/loose_agents.dart';
import '../data/send_to_seat.dart';
import 'option_sheet.dart';
import '../data/seat_poll.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:loggy/loggy.dart';

import '../chat/media_index.dart';
import '../chat/pane_preview.dart';
import '../chat/session_log.dart';
import '../chat/transcript.dart';
import '../data/chat_cache.dart';
import '../data/agent_jobs.dart';
import '../data/subagents.dart';
import '../data/attachments.dart';
import '../data/fleet.dart';
import '../data/needs_you.dart' show answerSettle, askMoved, askSig;
import '../data/git_status.dart';
import '../data/drafts.dart';
import '../data/outbox.dart';
import '../main.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import '../terminal/transport.dart';
import 'chat/chat_header.dart';
import 'agent_view_switch.dart';
import 'open_agents_on.dart';
import 'subagent_open.dart';
import 'artifact_viewer.dart';
import 'chat/diff_view.dart';
import 'agent_details.dart';
import 'chat/jobs_view.dart';
import 'chat/media_view.dart';
import 'chat/message_views.dart';
import 'chat/permission_dock.dart';
import 'chat/question_card.dart';
import 'common.dart';
import 'send_guard.dart';
import '../data/host_store.dart' show isDesktop;
import 'agent_panels.dart' show AgentPanelsToggle, PanelPreviewHost;
import 'agent_panels_sheet.dart' show PanelsStrip;
import 'desktop_shell.dart' show seatPanelKey, showsInPanel;
import 'tiles_screen.dart' show terminalInTile;
import 'needs_you_banner.dart';
import 'kit.dart';
import 'loose_agent_screen.dart';
import 'file_drop.dart';
import 'theme.dart';
import 'chat/composer.dart';
import 'chat/git_cards.dart';
import 'chat/restart.dart';
import 'chat/rig_chat_pager.dart';
import 'chat/session_pills.dart';

// What used to be defined here keeps its import path.
export 'chat/composer.dart';
export 'chat/git_cards.dart';
export 'chat/restart.dart';
export 'chat/session_pills.dart';
import 'permission_card.dart';
import 'permission_sheet.dart';
import 'status_shape.dart';
import 'action_rows.dart' show showActionRows;
import 'rig/seat_actions.dart' show seatMenuRows;
import 'rig/seat_sheet.dart' show showSeatSheet;
import 'rig_screen.dart' show editRigSpec;
import 'terminal_screen.dart';

part 'chat/chat_log.dart';
part 'chat/chat_media.dart';
part 'chat/chat_send.dart';
part 'chat/chat_sheets.dart';

@visibleForTesting
int chatFreshCap = 4 << 20;

/// Board 3a: a Claude Code seat as a chat, read live from its session log
/// over SSH. Messages go out through the daemon, like `rig send`.
/// Whether a plain 'open' of [seat] shows its chat: Settings › App › Open agents on is Chat, and the seat has one (a
/// Claude Code seat that is not a subagent's log). The sidebar, the tiles, the rig screen and the Inbox ask this.
bool opensAsChat(Seat seat) =>
    openAgentsOn.value == AgentView.chat && seat.isClaude && !isSubagentLog(seat.transcriptPath);

/// A seat's own screen as 'Open agents on' says: its chat or its terminal. A seat with no chat (Codex, a shell) is
/// its terminal either way.
Widget seatScreen(String rigName, Seat seat) =>
    seat.isClaude ? ChatScreen(rigName: rigName, seat: seat) : TerminalScreen(target: SeatTarget(rigName, seat));

/// A seat's chat. A rig's agent opens as a [RigChatPager] (swipe or tap between the rig's agents without leaving
/// the screen); an agent outside a rig, a subagent or a just-started session is a single [ChatPage].
class ChatScreen extends StatelessWidget {
  const ChatScreen(
      {super.key,
      required this.rigName,
      required this.seat,
      this.waitForLog = false,
      this.pendingMessage,
      this.loose,
      this.rigs = const [],
      this.asChat = false});
  final String rigName;
  final Seat seat;
  final LooseAgent? loose;
  final List<RigWithSeats> rigs;
  final String? pendingMessage;
  final bool waitForLog;

  /// The chat even on desktop, where a seat with a tmux session opens as its terminal (a real keyboard is there).
  final bool asChat;

  @override
  Widget build(BuildContext context) {
    showsInPanel(context, seatPanelKey(seat));
    return _build(context);
  }

  Widget _build(BuildContext context) => !asChat &&
          openAgentsOn.value == AgentView.terminal &&
          seat.sessionName != null &&
          pendingMessage == null &&
          !waitForLog &&
          !isSubagentLog(seat.transcriptPath)
      ? TerminalScreen(target: SeatTarget(rigName, seat), loose: loose, rigs: rigs)
      : seat.rigId.isNotEmpty &&
          rigName != 'no rig' &&
          loose == null &&
          pendingMessage == null &&
          !waitForLog &&
          !isSubagentLog(seat.transcriptPath)
      ? RigChatPager(rigName: rigName, seat: seat)
      : ChatPage(
          rigName: rigName, seat: seat, waitForLog: waitForLog, pendingMessage: pendingMessage, loose: loose, rigs: rigs);
}

class ChatPage extends StatefulWidget {
  const ChatPage(
      {super.key,
      required this.rigName,
      required this.seat,
      this.waitForLog = false,
      this.pendingMessage,
      this.loose,
      this.rigs = const [],
      this.embedded = false,
      this.active = true,
      this.draft,
      this.header});
  final String rigName;
  final Seat seat;

  /// The agent outside a rig this chat belongs to: the menu opens its details.
  final LooseAgent? loose;

  /// The host's rigs, offered on the details screen for adoption.
  final List<RigWithSeats> rigs;

  /// A message already sent, shown as pending until the log echoes it (the
  /// first prompt of a session started from the app).
  final String? pendingMessage;

  /// The session was just started: its log appears with its first message,
  /// so keep looking for it instead of reporting it missing. Only the exact
  /// log counts, never the newest one in the folder.
  final bool waitForLog;

  /// One page of the rig's [RigChatPager]: just the conversation and composer, no header or scaffold.
  final bool embedded;

  /// Only the page on screen reads the log, polls and holds the alerts focus; its neighbours wait.
  final bool active;

  /// The composer's text, kept by the pager so a draft survives the page being swiped away.
  final TextEditingController? draft;

  /// Where an [embedded] page tells the pager's header what it shows.
  final ValueNotifier<ChatHeaderInfo?>? header;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  /// [setState] for the extensions in chat/chat_*.dart, which may not call a protected member.
  void _set(VoidCallback fn) => setState(fn);

  late Seat _seat = widget.seat;

  /// An agent started by hand: no rig, so no daemon seat calls.
  bool get _loose => widget.seat.rigId.isEmpty;
  late var _transcript = ChatTranscript(sidechain: _subagent);

  /// A subagent's log: read only, and not cached (its name isn't unique).
  bool get _subagent => isSubagentLog(widget.seat.transcriptPath);
  SessionLogTail? _tail;
  String? _logPath;
  bool _locating = true;

  /// Waiting for a just-started session to write its log ([ChatPage.waitForLog]).
  bool _starting = false;
  DateTime? _startingSince;
  String? _error;
  String _status = 'connecting…';
  GitStatus? _git;
  List<AgentJob> _jobs = const [];
  List<Subagent> _subagents = const [];
  final List<String> _pending = [];
  String? _decision;

  /// The call [_decision] answered (null: the log had none).
  String? _decisionFor;

  /// The ask [_decision] answered and when: the seat still waiting later is a new ask, shown at once.
  String? _decisionSig;
  DateTime? _decisionAt;

  /// The keys of an answer are still being pressed: the old ask stays hidden and nothing else is pressed.
  bool _pressing = false;

  /// Drops the answer's note once the seat no longer waits or waits on something else.
  void _settleDecision(Seat fresh) {
    if (_decision == null || _pressing) return;
    final sig = _decisionSig, at = _decisionAt;
    if (!fresh.needsInput) {
      _decision = null;
    } else if (sig != null && at != null && askMoved(fresh, sig, at)) {
      // The log still has the answered call unfinished and the ask reads the same: the daemon lags, the menu
      // is the old one. Only another ask, or the call finishing, brings the dock back.
      final same = askSig(fresh) == sig;
      if (!(same && _callUnfinished(_decisionFor))) _decision = null;
    }
  }

  bool _callUnfinished(String? id) =>
      id != null && _transcript.items.any((i) => i is ToolCall && i.id == id && !i.done);

  /// Rows that have made their entrance, so a rebuilt row doesn't replay it.
  final _appeared = <String>{};
  bool _sending = false;
  late final _msg = widget.draft ?? TextEditingController();

  /// The rig's other agents, for the tabs under the header.
  List<Seat> _rigSeats = const [];

  /// What the composer's pickers last switched to, until the log shows it.
  String? _pickedModel;
  String? _pickedEffort;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _seatPoll;
  Timer? _gitPoll;
  Timer? _flush;
  Timer? _gitSoon;
  int _seenTools = 0;

  /// The cached copy, once looked up; the screen shows it until the log connects.
  CachedChat? _cached;
  bool _cacheChecked = false;
  bool _caching = false;
  String? _hostId;
  late final _key = chatKey(widget.seat);
  final _unsaved = <String>[];

  /// Where the saved lines end in the log: the next write starts here.
  int _savedOffset = 0;
  Timer? _save;
  Timer? _reconnect;
  Future<void> _saving = Future.value();

  /// A seeded chat's offset, until the full read replaces it. Lines read meanwhile are decoded in batches
  /// (as [_drain] does) into [_fresh], so the raw log is never held whole; [_hold] is the batch waiting.
  int? _seedOffset;
  final _hold = <String>[];
  var _fresh = ChatTranscript();
  final _freshSaved = <String>[];
  int _freshBytes = 0;
  bool _freshBusy = false;

  /// Raw lines kept for the cache while the full read is held: about what it stores (its own budget is 4 MB).
  /// The media of the older lines that are dropped is indexed here and stored with the first save.
  String? _claimed;
  LogIndex? _droppedIndex;
  bool _cutHistory = false; // older lines were dropped from the save, so the cache is marked truncated
  Timer? _swapCheck;
  bool _wantCache = false;
  final _scroll = ScrollController();

  final _listKey = GlobalKey();

  /// A row on screen just before a repaint that may add rows at the bottom, and where it was.
  (Key, double)? _anchor;

  @override
  void initState() {
    super.initState();
    if (widget.pendingMessage case final m?) _pending.add(m);
    outbox.addListener(_onOutbox);
    // The unsent text comes back (the pager's own controller already has it while the app runs).
    if (_msg.text.isEmpty) _msg.text = drafts.of(_outKey);
    _draftKey = _outKey;
    _msg.addListener(_keepDraft);
    if (widget.active) _start();
  }

  late final String _draftKey;
  void _keepDraft() => drafts.set(_draftKey, _msg.text);

  bool _started = false;
  bool _opened = false;

  /// Starts what only the page on screen does: the alerts focus, the log, and the seat and git polls.
  void _start() {
    if (_started) return;
    _started = true;
    needsYouAlerts.focusedSession = widget.seat.sessionName;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active) return;
      if (!_opened) {
        _opened = true;
        _open();
      }
      _loadGit();
      _seatPoll = Timer.periodic(seatPollEvery, (_) => _pollSeat());
      _panePoll = Timer.periodic(panePreviewEvery, (_) => _pollPane());
      _gitPoll = Timer.periodic(const Duration(seconds: 30), (_) => _loadGit());
    });
  }

  @override
  void didUpdateWidget(ChatPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
    if (!widget.active && old.active) {
      // Swiped away, not gone yet: stop polling; the page is disposed once it is off screen.
      _seatPoll?.cancel();
      _gitPoll?.cancel();
      _panePoll?.cancel();
      _seatPoll = _gitPoll = _panePoll = null;
      _preview = null;
      if (needsYouAlerts.focusedSession == widget.seat.sessionName) needsYouAlerts.focusedSession = null;
      _started = false;
    }
  }

  Route<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.embedded) return; // the pager registers the route
    seatScreenRoutes.remove(_route);
    _route = ModalRoute.of(context);
    if (_route != null) seatScreenRoutes.add(_route!);
  }

  @override
  void dispose() {
    seatScreenRoutes.remove(_route);
    if (needsYouAlerts.focusedSession == widget.seat.sessionName) needsYouAlerts.focusedSession = null;
    outbox.removeListener(_onOutbox);
    _msg.removeListener(_keepDraft);
    if (_claimed case final k?) openChatKeys.remove(k);
    for (final s in _subs) {
      s.cancel();
    }
    _saveNow();
    _swapCheck?.cancel();
    _scroll.dispose();
    _reconnect?.cancel();
    _tail?.close();
    _seatPoll?.cancel();
    _gitPoll?.cancel();
    _panePoll?.cancel();
    _flush?.cancel();
    _gitSoon?.cancel();
    if (widget.draft == null) _msg.dispose();
    super.dispose();
  }

  Timer? _panePoll;
  bool _paneBusy = false;

  /// The reply as it is being written, from the terminal pane; null when there is none.
  String? _preview;

  /// Whitespace folded; the pane shows rendered text, so a transcript's markdown markers are dropped too.
  static String _flat(String s) => s.replaceAll(RegExp(r'[`*]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// How often, and for how long, a just-started session is asked for its log.
  static const _startingPoll = Duration(seconds: 3);
  static const _startingPatience = Duration(minutes: 5);

  /// Log lines waiting to be decoded, in order.
  final _inbox = <String>[];
  bool _draining = false;

  /// Bumped by [_startOver], so a batch decoded for the old log is dropped.
  int _generation = 0;

  /// A log's history can be thousands of lines: decode big batches on
  /// another isolate so opening a chat doesn't freeze the screen.
  static Future<List<Object?>> _decode(List<String> lines) =>
      lines.length > 150 ? compute(decodeLogLines, lines) : Future.value(decodeLogLines(lines));

  bool _pollingLoose = false;

  void _onOutbox() {
    if (mounted) setState(() {});
  }

  /// This chat's queue in [outbox]; chats on different hosts can share a key.
  String get _outKey => '${AppScope.read(context).active?.id}|$_key';

  /// The `/model` alias a full model id belongs to.
  static String _modelAlias(String model) {
    for (final (alias, _, _) in claudeModels) {
      if (alias != 'default' && model.contains(alias)) return alias;
    }
    return model;
  }

  /// Media opens its preview; other files their uncommitted diff when git
  /// has one, else the file itself.
  void _openFile(String path) {
    if (isImagePath(path) || isVideoPath(path)) return _openMedia(path);
    final git = _git, root = git?.root;
    final rel = root != null && path.startsWith('$root/') ? path.substring(root.length + 1) : null;
    final changed = rel != null && git!.changeRows.any((r) => r.$2 == rel);
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => changed
            ? DiffScreen(root: root!, path: rel, untracked: git.untracked.contains(rel))
            : ArtifactViewer(path: path)));
  }

  /// Files this session changed, newest first, with their line counts.
  List<MapEntry<String, (int, int)?>> get _files => _transcript.changedFiles.entries.toList().reversed.toList();

  /// Pull requests this session opened, plus the branch's own PR.
  /// PRs this session opened, looked up once each by URL: name, state and size.
  final Map<String, PullRequest> _prInfo = {};

  /// "#12 Fix the retry" once looked up; "owner/repo #12" until then.
  String _prName(Uri u) => switch (_prInfo[u.toString()]) {
        final pr? => '#${pr.number} ${pr.title}',
        null => '${u.pathSegments[0]}/${u.pathSegments[1]} #${u.pathSegments.last}',
      };

  /// The PR's state, checks, review and size, when known.
  String? _prDetail(Uri u) => switch (_prInfo[u.toString()] ?? (u.toString() == _git?.pr?.url ? _git?.pr : null)) {
        final pr? => prLine(pr),
        null => null,
      };

  List<(String, Uri)> get _prs {
    final prs = <(String, Uri)>[
      for (final u in _transcript.openedPrs.reversed) (_prName(u), u),
    ];
    final branchPr = _git?.pr;
    if (branchPr?.url case final url? when !prs.any((p) => p.$2.toString() == url)) {
      prs.add(('#${branchPr!.number} ${branchPr.title}', Uri.parse(url)));
    }
    return prs;
  }

  void _openUrl(Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);

  /// A path shown relative to the session's folder.
  String _relative(String path) {
    final cwd = _seat.cwd ?? _transcript.cwd;
    return cwd != null && path.startsWith('$cwd/') ? path.substring(cwd.length + 1) : path;
  }

  /// A sheet with every file, artifact or pull request of one kind.
  /// Presses Esc in the agent's pane: Claude Code stops the turn it's on.
  Future<void> _interrupt() async {
    final host = AppScope.read(context).active;
    final api = AppScope.clientOf(context);
    if (host == null || api == null) return;
    try {
      await pressSeatKeys(host, _seat, const ['Escape']);
      if (mounted) toast(context, 'Interrupted ${_seat.logicalId}');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t interrupt it: $e');
    }
  }

  /// What the details screen shows: the seat, plus what this chat read.
  AgentDetails get _details {
    final running = _transcript.items.whereType<ToolCall>().where((t) => !t.done).lastOrNull;
    return AgentDetails(
      seat: _seat,
      model: _transcript.model,
      contextTokens: _transcript.contextTokens,
      outputTokens: _transcript.outputTokens == 0 ? null : _transcript.outputTokens,
      lastActivityAt: widget.loose?.lastActivityAt ?? _transcript.items.lastOrNull?.at,
      now: running == null ? null : '${running.verb} ${running.target}'.trim(),
      git: _git,
      prs: [for (final (name, url) in _prs) ([name, if (_prInfo[url.toString()]?.size case final z?) z].join(' · '), url)],
      files: _transcript.changedFiles,
      jobs: _jobs.where((j) => j.isShell).toList(),
      subagents: _subagents,
    );
  }

  static (int, int) _sum(List<MapEntry<String, (int, int)?>> files) => files.fold(
      (0, 0), (s, e) => e.value == null ? s : (s.$1 + e.value!.$1, s.$2 + e.value!.$2));

  /// The very light mint of finished subagents.
  static Color _doneMint(Tokens k) => Color.lerp(k.added, k.muted, 0.45)!;

  String? _mode;

  Future<void> _loadMode() async {
    final api = AppScope.clientOf(context);
    if (api == null) return;
    try {
      final m = await api.permissionMode(_seat);
      if (mounted) setState(() => _mode = m);
    } catch (_) {}
  }

  /// [child] for [item], easing in when the item just happened: history and
  /// a cached chat are simply there.
  Widget _appear(ChatItem item, Widget child, {String? key}) {
    final at = item.at;
    final fresh = at != null && DateTime.now().difference(at) < const Duration(minutes: 1);
    final animate = fresh && _appeared.add(item.key);
    if (!fresh) _appeared.add(item.key);
    return Appear(key: ValueKey(key ?? 'm${item.key}'), animate: animate, child: child);
  }

  /// Media paths per item, kept until the item's text grows (its result lands).
  final _mediaSeen = <String, (int, List<String>)>{};

  /// Paths checked on the host: true when they read there.
  final _mediaOk = <String, bool>{};
  bool _checkingMedia = false;
  DateTime? _mediaFailedAt;

  /// Chat items, with consecutive tool calls folded into one card, the files
  /// they wrote as tiles right after it, then the images and videos they made.
  /// A keyed row inside the chat list that is on screen, and its top edge. With [key], that row (null if it isn't built).
  (Key, double)? _rowOnScreen([Key? key]) {
    final list = _listKey.currentContext;
    final box = list?.findRenderObject();
    if (list == null || box is! RenderBox || !box.hasSize) return null;
    final top = box.localToGlobal(Offset.zero).dy;
    (Key, double)? found;
    void walk(Element e) {
      if (found != null) return;
      final k = e.widget.key, r = e.renderObject;
      if (k is ValueKey && r is RenderBox && r.attached && r.hasSize && (key == null || k == key)) {
        final y = r.localToGlobal(Offset.zero).dy;
        if (key != null || (y >= top && y < top + box.size.height)) {
          found = (k, y);
          return;
        }
      }
      e.visitChildren(walk);
    }

    list.visitChildElements(walk);
    return found;
  }

  List<Widget> _rows() {
    final out = <Widget>[];
    final group = <ToolCall>[];
    void flush() {
      if (group.isEmpty) return;
      out.add(_appear(group.first, ToolGroup(List.of(group), fetchFull: _fetchFull), key: 'g${group.first.id}'));
      final written = <String>[];
      final changes = <String, (int, int)>{};
      for (final c in group) {
        final p = c.writtenPath;
        if (p != null && !c.isError && !isImagePath(p) && !isVideoPath(p)) {
          written
            ..remove(p)
            ..add(p);
          final n = c.changes, sum = changes[p] ?? (0, 0);
          if (n != null) changes[p] = (sum.$1 + n.$1, sum.$2 + n.$2);
        }
      }
      if (written.isNotEmpty) {
        out.add(Padding(
          key: ValueKey('f${group.first.id}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          // Clip.none lets the tiles slide out to the screen edge, past the chat's padding.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(children: [
              for (final p in written) ...[
                if (p != written.first) const SizedBox(width: 8),
                ArtifactTile(path: p, changes: changes[p], onOpen: () => _openFile(p)),
              ],
            ]),
          ),
        ));
      }
      final media = _readable({for (final c in group) ..._mediaOf(c)});
      if (media.isNotEmpty) out.add(MediaRow(media, key: ValueKey('i${group.first.id}'), onOpen: _openMedia));
      group.clear();
    }

    for (final i in _transcript.items) {
      if (i is ToolCall) {
        group.add(i);
        continue;
      }
      flush();
      out.add(_appear(
          i,
          switch (i) {
            UserMessage(:final text) => UserBubble(text),
            AssistantMessage(:final text) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: AssistantBody(text),
              ),
            NoteItem(:final text) => NoteLine(text),
            ToolCall() => const SizedBox.shrink(),
          }));
      final media = i is AssistantMessage ? _readable(_mediaOf(i)) : const <String>[];
      if (media.isNotEmpty) out.add(MediaRow(media, key: ValueKey('i${i.key}'), onOpen: _openMedia));
    }
    flush();
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final git = _git;
    if (widget.active && _mode == null && _seat.permissionMode == null && !_loose) {
      _mode = '';
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _loadMode() : null);
    }
    final modeLabel = PermissionMode.fromWire(_mode?.isEmpty ?? true ? _seat.permissionMode : _mode)?.label;
    // The asking call is logged before the prompt shows: the newest one without a result.
    final asking = _waitingCall();
    final questions = AskQuestion.from(asking);
    // A logged question with no answer is waiting on the person, whatever the
    // seat's (possibly lagging) state says; it needs tmux to be answered.
    final askingNow = questions != null && _seat.sessionName != null && _seat.state != SeatState.stopped;
    final working = _seat.state == SeatState.working && !askingNow && _decision == null;
    // A permission (not a question) docks where the composer was.
    final permission = _seat.needsInput && _decision == null && questions == null && !_subagent;
    final rows = <Widget>[
      if (_tail?.truncated ?? _cached?.truncated ?? false) const NoteLine('Earlier messages not loaded'),
      ..._rows(),
      for (final p in _pending) Appear(key: ValueKey('p$p'), animate: true, child: UserBubble(p, pending: true)),
      for (final m in outbox.of(_outKey))
        Appear(
          key: ValueKey('o${m.id}'),
          animate: true,
          child: Unsent(m, onRetry: () => _retry(m), onDelete: () => outbox.remove(_outKey, m)),
        ),
      if ((_seat.needsInput || askingNow) && _decision == null && questions != null)
        QuestionCard(
          key: ValueKey('q${asking!.id}'),
          seatName: _seat.logicalId,
          questions: questions,
          onSend: (picks, other) => _pressSteps(questionSteps(questions, picks, other), [
            'Answered',
            for (var i = 0; i < questions.length; i++)
              other[i] ?? (picks[i].toList()..sort()).map((o) => questions[i].options[o].$1).join(', '),
          ].join(' · ')),
          onDecline: () => _answer(SeatAnswer.deny, 'Denied — ${_seat.logicalId} is waiting for instructions'),
        ),
      if ((_seat.needsInput || askingNow) && _decision == null)
        Padding(
          key: const ValueKey('waiting'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            const StatusShape(Status.needsYou, size: 10, semantics: false),
            const SizedBox(width: 8),
            Text('Waiting for you', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.accent)),
          ]),
        ),
      if (working && _preview != null && !_inTranscript(_preview!))
        WritingPreview(_preview!, key: const ValueKey('writing'))
      else if (working)
        Appear(key: const ValueKey('working'), animate: true, child: WorkingLine(activityLabel(asking))),
      if (_decision != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('${_decision!.startsWith('Denied') ? '✕' : (_decision!.startsWith('May have arrived') ? '?' : '✓')} $_decision',
              style: TextStyle(fontSize: 13, color: k.muted)),
        ),
    ];

    Widget body;
    // shortcut: a log with no displayable lines spins until its first message; the status can't tell, since 'live' fires before any bytes.
    if (_starting && _transcript.items.isEmpty) {
      body = StartingNotice(seat: _seat, pending: _pending, onTerminal: _toTerminal);
    } else if (_locating || (rows.every((r) => r is NoteLine) && _error == null)) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ListView(padding: const EdgeInsets.all(20), children: [
        ErrorBanner(_error!, margin: EdgeInsets.zero),
        const SizedBox(height: 16),
        Row(children: [
          OutlinedButton(onPressed: _open, child: const Text('Try again')),
          const SizedBox(width: 8),
          FilledButton(onPressed: _toTerminal, child: const Text('Open terminal')),
        ]),
      ]);
    } else {
      // New rows at the bottom push the page up: after the frame, scroll back by how far the row on screen moved.
      if (_anchor != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final a = _anchor;
          _anchor = null;
          if (a == null || !_scroll.hasClients) return;
          final now = _rowOnScreen(a.$1);
          if (now == null) return;
          final p = _scroll.position;
          p.jumpTo((p.pixels + a.$2 - now.$2).clamp(0.0, p.maxScrollExtent));
        });
      }
      // Built on first lookup, once per build: a scan per child was O(rows) for every visible row.
      late final rowIndex = {
        for (var i = 0; i < rows.length; i++)
          if (rows[i].key case final k?) k: rows.length - 1 - i,
      };
      body = ListView.builder(
        key: _listKey,
        controller: _scroll,
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        itemCount: rows.length,
        itemBuilder: (_, i) => rows[rows.length - 1 - i],
        // New messages shift every index; follow keys so an open tool group stays open.
        findChildIndexCallback: (key) => rowIndex[key],
      );
    }

    final cwd = _seat.cwd ?? _transcript.cwd;
    final project = cwd == null ? null : folderName(cwd);
    final worktree = worktreeName(cwd);
    final where = [
      if (project != null) project,
      if (widget.rigName != 'no rig' || project == null) widget.rigName,
    ].join(' › ');
    final subtitle = [
      where,
      if (worktree != null) worktree,
      if (_starting && _logPath == null) 'starting…',
      if ((_logPath != null || _cached != null) && _status != 'live') _status,
    ].join(' · ');
    if (widget.embedded && widget.active) _publishHeader(subtitle, git);
    final content = <Widget>[
        Expanded(child: ImageDropTarget(onPaste: _addPaths, child: body)),
        if (_sessionPills() case final pills?) pills,
        // The phone: the agent's files and images, a tap from the sheet (nothing when it has none).
        if (!isDesktop) PanelsStrip(seat: _seat),
        canRestartInTmux(_seat)
              ? RestartBar(onRestart: () => confirmRestartInTmux(context, _seat))
              : permission
                  ? _permissionDock(_permissionCall(), modeLabel)
                  : Composer(
            controller: _msg,
            sending: _sending,
            onSend: _send,
            onAttach: _attach,
            enabled: _seat.sessionName != null,
            hint: _subagent
                ? 'Subagent: read only'
                : (_seat.sessionName == null ? 'Not in tmux: read only' : 'Reply to ${_seat.logicalId}…'),
            model: switch (_pickedModel ?? _transcript.model ?? _seat.model) {
              null => 'Default',
              final m => claudeModels.where((o) => o.$1 == m).firstOrNull?.$2 ?? modelLabel(m),
            },
            effort: switch (_pickedEffort ?? _seat.effort) {
              null => 'Auto',
              final e => claudeEfforts.where((o) => o.$1 == e).firstOrNull?.$2 ?? e,
            },
            mode: modeLabel,
            working: _seat.state == SeatState.working,
            onInterrupt: _seat.sessionName == null || _subagent ? null : _interrupt,
            onModel: _seat.isClaude && _seat.sessionName != null ? _pickModel : null,
            onEffort: _seat.isClaude && _seat.sessionName != null ? _pickEffort : null,
            onMode: _loose || _subagent ? null : _openPermissions,
          ),
    ];
    if (widget.embedded) return Column(children: content);
    return Scaffold(
      body: Column(children: [
        chatAgentHeader(
          context,
          seat: _seat,
          title: _seat.logicalId,
          subtitle: subtitle,
          onMenu: _showMenu,
          onSwitch: _toTerminal,
          git: git,
          onGit: (g) => showGitSheet(context, g),
          // The Mac: the panels toggle in the agent row, and the dock with its previews beside the chat.
          extraActions: [if (isDesktop) const AgentPanelsToggle()],
        ),
        if (isDesktop)
          Expanded(child: PanelPreviewHost(seat: _seat, headerBack: Navigator.of(context).canPop(), child: Column(children: content)))
        else
          ...content,
      ]),
    );
  }

  ChatHeaderInfo? _published;

  /// Tells the pager's header what this page is showing (after the frame: the header is rebuilt by it).
  void _publishHeader(String subtitle, GitStatus? git) {
    final info = ChatHeaderInfo(
        seatId: _seat.logicalId, subtitle: subtitle, git: git, rigSeats: _rigSeats, onMenu: _showMenu);
    if (_published?.sameAs(info) ?? false) return;
    _published = info;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && _published == info) widget.header?.value = info;
    });
  }

  /// The pending permission, docked in the composer's place: the logged call
  /// when there is one, else what the daemon says it's asking.
  Widget _permissionDock(ToolCall? call, String? modeLabel) {
    final c = call;
    final ask = c == null ? PermissionAsk.from(_seat) : PermissionAsk(tool: c.name, detail: _detail(c));
    final note = c?.name == 'Bash' ? c!.input['description'] : null;
    return PermissionDock(
      key: ValueKey('perm${c?.id}'),
      who: _seat.logicalId,
      ask: ask,
      question: ask.question(_seat.logicalId),
      note: note is String ? note : null,
      mode: modeLabel,
      onAllow: () => _answer(SeatAnswer.allowOnce, 'Allowed once'),
      onDeny: () => _answer(SeatAnswer.deny, 'Denied — ${_seat.logicalId} is waiting for instructions'),
      onAlways: _loose ? null : () => _answer(SeatAnswer.allowAlways, 'Always allowed for ${_seat.logicalId}'),
      onDenyWithNote: _seat.sessionName == null ? null : _denyWithNote,
      onAllowAuto: _loose || !_seat.isClaude || modeLabel == PermissionMode.auto.label ? null : _allowAndAuto,
    );
  }
}

/// The full thing the call will do: the whole command, not its description.
String _detail(ToolCall c) {
  final v = c.input[c.name == 'Bash' ? 'command' : 'file_path'];
  return v is String && v.isNotEmpty ? v : (c.target.isEmpty ? c.name : c.target);
}
