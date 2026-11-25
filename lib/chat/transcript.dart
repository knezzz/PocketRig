import 'dart:convert';

/// A published artifact's link, in an Artifact tool result or the text around it.
final artifactUrl = RegExp(r'https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9-]+');

/// Claude Code's session log (`~/.claude/projects/<slug>/<session>.jsonl`)
/// turned into chat items. One JSON object per line; an assistant turn is
/// spread over several lines that share `message.id`, one content block per
/// line. Tool results come back on `user` lines and pair with their
/// `tool_use` by id. Unknown lines are skipped, never thrown on.
sealed class ChatItem {
  ChatItem(this.key, this.at);

  /// Stable across re-parses (the line's uuid or the message id).
  final String key;
  final DateTime? at;
}

class UserMessage extends ChatItem {
  UserMessage(super.key, super.at, this.text);
  final String text;
}

class AssistantMessage extends ChatItem {
  AssistantMessage(super.key, super.at, this.text);
  String text;
}

/// A local command or a system notice, shown as a small centered line.
class NoteItem extends ChatItem {
  NoteItem(super.key, super.at, this.text);
  final String text;
}

class ToolCall extends ChatItem {
  ToolCall(super.key, super.at, {required this.id, required this.name, required this.input});
  final String id;
  final String name;
  Map<String, Object?> input;
  String? result;
  bool isError = false;

  /// Restored from the cache with its long text cut; the full call is in the log.
  bool clipped = false;

  /// The full result's line count, when [clipped] cut the result.
  int? fullLines;

  /// The true [changes], when [clipped] cut the input they're counted from.
  (int, int)? fullChanges;

  /// Lines added and removed; null for calls that don't edit text.
  (int, int)? get changes => fullChanges ?? lineChanges(name, input);
  bool get done => result != null;

  /// READ / EDIT / BASH …, for the folded row.
  String get verb => switch (name) {
        'Read' => 'READ',
        'Write' => 'WRITE',
        'Edit' || 'MultiEdit' || 'NotebookEdit' => 'EDIT',
        'Bash' || 'BashOutput' => 'BASH',
        'Glob' => 'GLOB',
        'Grep' => 'GREP',
        'WebFetch' => 'FETCH',
        'WebSearch' => 'SEARCH',
        'Task' || 'Agent' => 'AGENT',
        'TodoWrite' => 'TODO',
        'AskUserQuestion' => 'ASK',
        // mcp__server__tool → TOOL
        _ => name.split('__').last.toUpperCase(),
      };

  /// What the tool acted on: a path, a command, a pattern.
  String get target {
    String? s(String k) {
      final v = input[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    return switch (name) {
      'Bash' => s('description') ?? s('command') ?? '',
      'Glob' || 'Grep' => [s('pattern'), s('path')].whereType<String>().join(' in '),
      'WebFetch' => s('url') ?? '',
      'WebSearch' => s('query') ?? '',
      'Task' || 'Agent' => s('description') ?? '',
      'TodoWrite' => '${(input['todos'] as List?)?.length ?? 0} items',
      'AskUserQuestion' => switch (input['questions']) {
          [Map q, ...] => '${q['question'] ?? ''}',
          _ => '',
        },
      'Skill' => s('skill') ?? '',
      _ => s('file_path') ?? s('notebook_path') ?? s('path') ?? s('command') ?? s('pattern') ?? '',
    };
  }

  /// A file this call wrote or edited, for the artifact tile.
  String? get writtenPath => switch (name) {
        'Write' || 'Edit' || 'MultiEdit' => input['file_path'] as String?,
        'NotebookEdit' => input['notebook_path'] as String?,
        _ => null,
      };

  /// One short line of result: "120 lines", "exit ok", the first line.
  String get shortResult {
    final r = result;
    if (r == null) return 'running…';
    if (isError) return 'error: ${_firstLine(r)}';
    switch (name) {
      case 'Read':
        final n = fullLines ?? '\n'.allMatches(r).length + (r.isEmpty ? 0 : 1);
        return n == 1 ? '1 line' : '$n lines';
      case 'Write':
        return 'written';
      case 'Edit' || 'MultiEdit' || 'NotebookEdit':
        return 'edited';
      case 'Glob':
        final n = fullLines ?? (r.trim().isEmpty ? 0 : '\n'.allMatches(r.trim()).length + 1);
        return n == 1 ? '1 file' : '$n files';
    }
    final first = _firstLine(r);
    return first.isEmpty ? 'done' : first;
  }

  static String _firstLine(String s) {
    final line = s.trim().split('\n').first.trim();
    return line.length > 80 ? '${line.substring(0, 80)}…' : line;
  }
}

class ChatTranscript {
  ChatTranscript({this.sidechain = false});

  /// A subagent's own log, where every line is a sidechain. Otherwise
  /// sidechain lines are skipped: older Claude Code wrote them into the parent's log.
  final bool sidechain;

  final List<ChatItem> items = [];
  final Map<String, AssistantMessage> _assistantById = {};
  final Map<String, ToolCall> _toolsById = {};
  final Set<String> _seen = {};

  /// The model of the newest assistant turn (`claude-opus-4-5-20251101`).
  String? model;

  /// Tokens the newest turn read (input + cache): roughly the context in use.
  int? contextTokens;

  /// Output tokens per assistant message (the log repeats a message's usage on
  /// each of its lines, so they're keyed by message id, not summed per line).
  final Map<String, int> _outputById = {};
  int get outputTokens => _outputById.values.fold(0, (a, b) => a + b);

  /// The session's working folder and branch, from the newest line.
  String? cwd;
  String? gitBranch;

  /// Files written or edited, newest touch last.
  List<String> get artifacts {
    final order = <String>[];
    for (final i in items) {
      if (i is ToolCall && i.writtenPath != null) {
        order.remove(i.writtenPath);
        order.add(i.writtenPath!);
      }
    }
    return order;
  }

  /// Files written or edited without error, newest touch last, with the
  /// lines added and removed across every touch (null: not counted).
  Map<String, (int, int)?> get changedFiles {
    final out = <String, (int, int)?>{};
    for (final c in items.whereType<ToolCall>()) {
      final p = c.writtenPath;
      if (p == null || c.isError) continue;
      final before = out.remove(p), n = c.changes;
      out[p] = n == null ? before : (n.$1 + (before?.$1 ?? 0), n.$2 + (before?.$2 ?? 0));
    }
    return out;
  }

  static final _prUrl = RegExp(r'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+');

  /// Pages the Artifact tool published: the file it sent, and its claude.ai link.
  List<(String file, Uri url)> get publishedArtifacts {
    final out = <String, String>{};
    for (final c in items.whereType<ToolCall>()) {
      final url = c.name == 'Artifact' && !c.isError ? artifactUrl.firstMatch(c.result ?? '')?.group(0) : null;
      if (url == null) continue;
      out.remove(url);
      out[url] = (c.input['file_path'] as String?)?.split('/').last ?? 'Artifact';
    }
    return [for (final e in out.entries) (e.value, Uri.parse(e.key))];
  }

  /// Pull requests this session opened with `gh pr create`, from the link it printed.
  List<Uri> get openedPrs => {
        for (final c in items.whereType<ToolCall>())
          if (c.name == 'Bash' && !c.isError && '${c.input['command']}'.contains('pr create'))
            ..._prUrl.allMatches(c.result ?? '').map((m) => m.group(0)!),
      }.map(Uri.parse).toList();

  void addAll(Iterable<String> lines) => lines.forEach(add);

  /// Adds one JSONL line. Returns true when the chat changed.
  bool add(String line) => addDecoded(decodeLogLine(line));

  /// Adds a line [decodeLogLine] already decoded (maybe on another isolate).
  /// A line whose fields have unexpected types is skipped.
  bool addDecoded(Object? j) {
    try {
      return _addDecoded(j);
    } catch (_) {
      return false;
    }
  }

  bool _addDecoded(Object? j) {
    if (j is! Map) return false;
    final uuid = j['uuid'] as String?;
    if (uuid != null && !_seen.add(uuid)) return false;
    if (j['isSidechain'] == true && !sidechain) return false;
    cwd = j['cwd'] as String? ?? cwd;
    gitBranch = j['gitBranch'] as String? ?? gitBranch;
    final at = DateTime.tryParse(j['timestamp'] as String? ?? '');
    final key = uuid ?? '${items.length}';
    switch (j['type']) {
      case 'user':
        return _user(j, key, at);
      case 'assistant':
        return _assistant(j, key, at);
      case 'system':
        final text = j['content'];
        if (text is String && text.trim().isNotEmpty && j['level'] != 'debug') {
          items.add(NoteItem(key, at, _stripTags(text)));
          return true;
        }
    }
    return false;
  }

  bool _user(Map j, String key, DateTime? at) {
    if (j['isMeta'] == true) return false;
    final msg = j['message'];
    if (msg is! Map) return false;
    final content = msg['content'];
    if (content is String) return _userText(content, key, at, compact: j['isCompactSummary'] == true);
    if (content is! List) return false;
    var changed = false;
    final texts = <String>[];
    for (final block in content.whereType<Map>()) {
      switch (block['type']) {
        case 'tool_result':
          final call = _toolsById[block['tool_use_id']];
          if (call != null) {
            call.result = _resultText(block['content']);
            call.isError = block['is_error'] == true;
            call.clipped = call.clipped || block[_clipMark] == true;
            call.fullLines = block[_linesMark] as int?;
            changed = true;
          }
        case 'text':
          if (block['text'] is String) texts.add(block['text'] as String);
      }
    }
    if (texts.isNotEmpty) changed = _userText(texts.join('\n'), key, at) || changed;
    return changed;
  }

  bool _userText(String text, String key, DateTime? at, {bool compact = false}) {
    if (compact) {
      items.add(NoteItem(key, at, 'Conversation compacted'));
      return true;
    }
    // Text Claude Code wraps around what was typed: context for the model,
    // never shown; and pasted text, shown as typed.
    text = text
        .replaceAll(RegExp(r'<(system-reminder|artifact-view-context)\b[^>]*>.*?</\1>', dotAll: true), '')
        .replaceAllMapped(RegExp(r'<pasted_content id="[^"]*">\n?(.*?)\n?</pasted_content id="[^"]*">', dotAll: true),
            (m) => m[1]!)
        .trim();
    // Notices from Claude Code itself, as small lines.
    final notice = switch (text) {
      _ when text.startsWith('<task-notification>') => _tag('summary', text) ?? 'Background task finished',
      _ when text.startsWith('<ci-monitor-event>') =>
        ['CI update', ...RegExp(r'PR #\d+').allMatches(text).take(1).map((m) => m[0]!)].join(' on '),
      _ when text.startsWith('<create-pr-command>') => 'Create PR',
      _ => null,
    };
    if (notice != null) {
      items.add(NoteItem(key, at, notice));
      return true;
    }
    // Slash commands and their output arrive as tagged user text.
    if (text.contains('<command-name>') || text.contains('<local-command-stdout>')) {
      final name = [_tag('command-name', text), _tag('command-args', text)].whereType<String>().join(' ').trim();
      final out = _tag('local-command-stdout', text);
      final note = [if (name.isNotEmpty) name, if (out != null && out.isNotEmpty) out].join(' · ');
      if (note.isEmpty) return false;
      items.add(NoteItem(key, at, note));
      return true;
    }
    // `!cmd` typed in Claude Code: logged as tagged user text, the command on
    // one line and its output on the next. Shown like the agent's own Bash calls.
    if (_tag('bash-input', text) case final cmd?) {
      final call = _bang = ToolCall(key, at, id: key, name: 'Bash', input: {'command': cmd});
      items.add(call);
      return true;
    }
    if (text.contains('<bash-stdout>') || text.contains('<bash-stderr>')) {
      final out = _tag('bash-stdout', text) ?? '', err = _tag('bash-stderr', text) ?? '';
      final call = _bang;
      _bang = null;
      if (call == null) return false;
      call
        ..result = [out, err].where((s) => s.isNotEmpty).join('\n')
        ..isError = out.isEmpty && err.isNotEmpty;
      return true;
    }
    if (text.isEmpty) return false;
    if (text.startsWith('[Request interrupted')) {
      items.add(NoteItem(key, at, 'Interrupted'));
      return true;
    }
    items.add(UserMessage(key, at, text));
    return true;
  }

  bool _assistant(Map j, String key, DateTime? at) {
    final msg = j['message'];
    if (msg is! Map) return false;
    // `<synthetic>` marks Claude Code's own notices, not a model.
    if (msg['model'] case final String m when m.isNotEmpty && !m.startsWith('<')) model = m;
    final id = msg['id'] as String? ?? key;
    if (msg['usage'] case final Map u) {
      int n(String k) => (u[k] as num?)?.toInt() ?? 0;
      final read = n('input_tokens') + n('cache_read_input_tokens') + n('cache_creation_input_tokens');
      if (read > 0) contextTokens = read;
      _outputById[id] = n('output_tokens');
    }
    final content = msg['content'];
    if (content is! List) return false;
    var changed = false;
    for (final block in content.whereType<Map>()) {
      switch (block['type']) {
        case 'text':
          final text = block['text'];
          if (text is! String || text.trim().isEmpty) continue;
          final existing = _assistantById[id];
          // A new text block after a tool call starts a new bubble.
          if (existing != null && identical(items.lastOrNull, existing)) {
            existing.text = '${existing.text}\n\n$text';
          } else {
            final m = AssistantMessage('$id#${items.length}', at, text);
            _assistantById[id] = m;
            items.add(m);
          }
          changed = true;
        case 'tool_use':
          final toolId = block['id'] as String?;
          if (toolId == null || _toolsById.containsKey(toolId)) continue;
          final input = block['input'];
          final call = ToolCall(toolId, at,
              id: toolId,
              name: block['name'] as String? ?? 'tool',
              input: input is Map ? input.cast<String, Object?>() : const {})
            ..clipped = block[_clipMark] == true
            ..fullChanges = switch (block[_changesMark]) { [int added, int removed] => (added, removed), _ => null };
          _toolsById[toolId] = call;
          items.add(call);
          changed = true;
      }
    }
    return changed;
  }

  static String _resultText(Object? c) {
    if (c is String) return c;
    if (c is List) {
      return c.whereType<Map>().map((b) => b['type'] == 'text' ? '${b['text'] ?? ''}' : '[${b['type']}]').join('\n');
    }
    return c == null ? '' : '$c';
  }

  /// The last `!cmd`, until its output line lands.
  ToolCall? _bang;

  /// What's inside `<name>…</name>` in [s], trimmed and unescaped; null without the tag.
  static String? _tag(String name, String s) => RegExp('<$name>(.*?)</$name>', dotAll: true)
      .firstMatch(s)
      ?.group(1)!
      .trim()
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  static String _stripTags(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'};
const _videoExts = {'mp4', 'mov', 'm4v', 'webm'};

String _ext(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool isImagePath(String path) => _imageExts.contains(_ext(path));
bool isVideoPath(String path) => _videoExts.contains(_ext(path));

final _separators = RegExp('[\\s"\'`()\\[\\]<>|;,=]+');
final _trailing = RegExp(r'[.:!?*]+$');

/// Image and video files [text] names: absolute, `~/`, or relative to [cwd].
/// URLs are left out: those aren't on the host.
List<String> mediaPathsIn(String text, String? cwd) {
  final out = <String>[];
  for (final word in text.split(_separators)) {
    final t = word.replaceAll(_trailing, '');
    if (t.contains('://') || !(isImagePath(t) || isVideoPath(t))) continue;
    final path = t.startsWith('/') || t.startsWith('~/')
        ? t
        : cwd == null
            ? null
            : '$cwd/${t.startsWith('./') ? t.substring(2) : t}';
    if (path != null && !out.contains(path)) out.add(path);
  }
  return out;
}

/// Images and videos the person attached (uploaded to the host's
/// `.cache/pocketrig/uploads`), pulled out of their message: the text left, and the paths.
(String, List<String>) splitUploads(String text) {
  final media = <String>[];
  final rest = text.replaceAllMapped(RegExp(r'\S*/\.cache/pocketrig/uploads/\S+'), (m) {
    final p = m[0]!;
    if (!isImagePath(p) && !isVideoPath(p)) return p;
    if (!media.contains(p)) media.add(p);
    return '';
  });
  return (media.isEmpty ? text : rest.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim(), media);
}

/// Every string in a tool call's input, nested lists and maps included.
Iterable<String> _strings(Object? v) sync* {
  if (v is String) yield v;
  if (v is Map) {
    for (final x in v.values) {
      yield* _strings(x);
    }
  }
  if (v is List) {
    for (final x in v) {
      yield* _strings(x);
    }
  }
}

/// Images and videos [item] made or mentions on the host.
List<String> mediaOf(ChatItem item, String? cwd) => switch (item) {
      ToolCall(:final input, :final result) => {
          for (final s in [..._strings(input), if (result != null) result]) ...mediaPathsIn(s, cwd)
        }.toList(),
      AssistantMessage(:final text) => mediaPathsIn(text, cwd),
      _ => const <String>[],
    };

/// A log line's JSON, or null for blank or broken lines.
Object? decodeLogLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    return jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
}

/// [decodeLogLine] over a batch: top level, for `compute`.
List<Object?> decodeLogLines(List<String> lines) => [for (final l in lines) decodeLogLine(l)];

const _clipMark = '_clip', _linesMark = '_lines', _changesMark = '_changes';

/// Lines a [name] call with this [input] added and removed. Lines an edit keeps
/// (its context) don't count, wherever they moved to.
/// shortcut: a Write counts every line as added, since the log doesn't hold the file it replaced.
(int, int)? lineChanges(String? name, Object? input) {
  if (input is! Map) return null;
  List<String> lines(Object? s) => s is String && s.isNotEmpty ? s.replaceFirst(RegExp(r'\n$'), '').split('\n') : const [];
  (int, int) edit(Map e) {
    final before = lines(e['old_string']), after = lines(e['new_string']);
    final left = <String, int>{};
    for (final l in before) {
      left[l] = (left[l] ?? 0) + 1;
    }
    var kept = 0;
    for (final l in after) {
      if ((left[l] ?? 0) > 0) {
        left[l] = left[l]! - 1;
        kept++;
      }
    }
    return (after.length - kept, before.length - kept);
  }

  return switch (name) {
    'Write' => (lines(input['content']).length, 0),
    'Edit' => edit(input),
    'MultiEdit' => (input['edits'] is List ? input['edits'] as List : const []).whereType<Map>().map(edit).fold<(int, int)>(
        (0, 0), (sum, e) => (sum.$1 + e.$1, sum.$2 + e.$2)),
    _ => null,
  };
}

/// Text longer than this is cut for the cache, down to [_clipKeep] characters.
const _clipOver = 2048, _clipKeep = 300;

/// The [line] to keep on the phone: only what [ChatTranscript] reads, without
/// images, thinking or the log's duplicates, and with long tool input and
/// output cut (marked, so the full call can be fetched again). What you and
/// the agent said is kept whole.
String slimLogLine(String line) {
  final j = jsonDecode(line) as Map;
  final out = <String, Object?>{
    for (final k in const ['uuid', 'type', 'cwd', 'gitBranch', 'timestamp', 'level', 'content', 'isCompactSummary'])
      if (j[k] != null) k: j[k],
  };
  final msg = j['message'];
  if (msg is Map) {
    final content = msg['content'];
    out['message'] = {
      if (msg['id'] != null) 'id': msg['id'],
      if (msg['model'] != null) 'model': msg['model'],
      if (msg['usage'] case final Map u)
        'usage': {
          for (final k in const ['input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens', 'output_tokens'])
            if (u[k] != null) k: u[k],
        },
      'content': content is List ? content.whereType<Map>().map(_slimBlock).nonNulls.toList() : content,
    };
  }
  return jsonEncode(out);
}

Map<String, Object?>? _slimBlock(Map b) {
  switch (b['type']) {
    case 'text':
      return {'type': 'text', 'text': b['text']};
    case 'tool_use':
      var cut = false;
      Object? clip(Object? v) {
        if (v is String && v.length > _clipOver) {
          cut = true;
          return v.substring(0, _clipKeep);
        }
        if (v is Map) return {for (final e in v.entries) e.key: clip(e.value)};
        if (v is List) return [for (final x in v) clip(x)];
        return v;
      }

      final input = clip(b['input']);
      final changes = cut ? lineChanges(b['name'] as String?, b['input']) : null;
      return {
        'type': 'tool_use',
        'id': b['id'],
        'name': b['name'],
        'input': input,
        if (cut) _clipMark: true,
        if (changes != null) _changesMark: [changes.$1, changes.$2],
      };
    case 'tool_result':
      final text = ChatTranscript._resultText(b['content']);
      final cut = text.length > _clipOver;
      return {
        'type': 'tool_result',
        'tool_use_id': b['tool_use_id'],
        if (b['is_error'] == true) 'is_error': true,
        'content': cut ? text.substring(0, _clipKeep) : text,
        if (cut) _clipMark: true,
        if (cut) _linesMark: '\n'.allMatches(text.trim()).length + 1,
      };
  }
  return null; // images and thinking: the chat doesn't show them
}

/// Every string in a tool call's input, for the media index.
Iterable<String> toolInputStrings(Object? input) => _strings(input);

/// A tool result's text, for the media index.
String toolResultText(Object? content) => ChatTranscript._resultText(content);

/// A run of prose or a fenced code block inside assistant text.
class TextSegment {
  TextSegment.prose(this.body)
      : isCode = false,
        language = null;
  TextSegment.code(this.body, this.language) : isCode = true;
  final bool isCode;
  final String? language;
  final String body;
  bool get isMermaid => isCode && language == 'mermaid';
}

/// Splits Markdown into prose and ``` fences, so code and mermaid blocks get
/// their own renderers. An unclosed fence (still streaming) runs to the end.
List<TextSegment> splitFences(String text) {
  final out = <TextSegment>[];
  final lines = text.split('\n');
  final prose = StringBuffer();
  StringBuffer? code;
  String? lang;
  String fence = '';
  void flushProse() {
    final p = prose.toString().trim();
    if (p.isNotEmpty) out.add(TextSegment.prose(p));
    prose.clear();
  }

  for (final line in lines) {
    final m = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*([\w+.#-]*)').firstMatch(line);
    if (code == null && m != null) {
      flushProse();
      fence = m.group(1)!;
      lang = (m.group(2) ?? '').toLowerCase();
      code = StringBuffer();
      continue;
    }
    if (code != null) {
      if (line.trim().startsWith(fence) && line.trim().replaceAll(fence[0], '').isEmpty) {
        out.add(TextSegment.code(code.toString().replaceFirst(RegExp(r'\n$'), ''), lang!.isEmpty ? null : lang));
        code = null;
      } else {
        code.writeln(line);
      }
      continue;
    }
    prose.writeln(line);
  }
  if (code != null) out.add(TextSegment.code(code.toString().replaceFirst(RegExp(r'\n$'), ''), lang!.isEmpty ? null : lang));
  flushProse();
  return out;
}
