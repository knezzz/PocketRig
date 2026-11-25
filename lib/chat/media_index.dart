import 'transcript.dart';

/// One image, video, file or artifact a chat made or mentions.
/// [kind] is `image | video | file | artifact`; [ref] is the host path, or the
/// claude.ai URL for an artifact ('' until its result arrives). [at] is the
/// log line's time in ms since epoch.
typedef MediaHit = ({String kind, String ref, String? name, String? toolId, int at});

/// What a batch of full log lines says about media. Plain records and lists,
/// so it crosses isolates.
typedef LogIndex = ({
  List<MediaHit> hits,
  Set<String> errorIds,
  Map<String, String> artifactUrls,
});

/// Reads media out of the full lines, before they are slimmed, so clipping
/// never hides a path. A broken line is skipped.
LogIndex indexLogLines(List<String> lines) {
  final hits = <MediaHit>[];
  final errorIds = <String>{};
  final artifactUrls = <String, String>{};
  for (final line in lines) {
    // A line whose fields have unexpected types is skipped, not fatal to the batch.
    try {
      final j = decodeLogLine(line);
      if (j is! Map) continue;
      if (j['isSidechain'] == true) continue;
      final at = DateTime.tryParse(j['timestamp'] as String? ?? '')?.millisecondsSinceEpoch ?? 0;
      final cwd = j['cwd'] as String?;
      final content = (j['message'] as Map?)?['content'];
      if (content is! List) continue;
      void add(String kind, String ref, {String? name, String? toolId}) =>
          hits.add((kind: kind, ref: ref, name: name, toolId: toolId, at: at));
      void addMedia(String text, String? toolId) {
        for (final p in mediaPathsIn(text, cwd)) {
          add(isVideoPath(p) ? 'video' : 'image', p, toolId: toolId);
        }
      }

      for (final b in content.whereType<Map>()) {
        switch (b['type']) {
          case 'text' when j['type'] == 'assistant' && b['text'] is String:
            addMedia(b['text'] as String, null);
          case 'tool_use':
            final id = b['id'] as String?;
            final input = (b['input'] as Map?)?.cast<String, Object?>() ?? {};
            final call = ToolCall('', null, id: id ?? '', name: '${b['name']}', input: input);
            if (call.writtenPath case final p?) {
              if (!isImagePath(p) && !isVideoPath(p)) add('file', p, toolId: id);
            }
            if (call.name == 'Artifact') {
              add('artifact', '', name: (input['file_path'] as String?)?.split('/').last ?? 'Artifact', toolId: id);
            }
            for (final s in toolInputStrings(input)) {
              addMedia(s, id);
            }
          case 'tool_result':
            final id = b['tool_use_id'] as String?;
            final text = toolResultText(b['content']);
            if (b['is_error'] == true) {
              if (id != null) errorIds.add(id);
              continue;
            }
            final url = artifactUrl.firstMatch(text)?.group(0);
            if (id != null && url != null) artifactUrls[id] = url;
            // Like prose, not a tool's own: output (ls, git status) lists files the agent never looked at.
            addMedia(text, null);
        }
      }
    } catch (_) {}
  }
  return (hits: hits, errorIds: errorIds, artifactUrls: artifactUrls);
}

/// [a] then [b], as if their lines had been indexed together.
LogIndex mergeLogIndex(LogIndex a, LogIndex b) => (
      hits: [...a.hits, ...b.hits],
      errorIds: {...a.errorIds, ...b.errorIds},
      artifactUrls: {...a.artifactUrls, ...b.artifactUrls},
    );

/// For `compute`: slim the lines for storage and index the media in them.
({List<String> slim, LogIndex index}) slimAndIndex(List<String> lines) {
  final slim = <String>[];
  for (final l in lines) {
    try {
      slim.add(slimLogLine(l));
    } catch (_) {
      slim.add(l);
    }
  }
  return (slim: slim, index: indexLogLines(lines));
}
