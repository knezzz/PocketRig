import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../chat/transcript.dart';
import '../common.dart';
import '../info_bar.dart';
import '../kit.dart' show DashedBorder, Panel, RowTile;
import '../thinking_dots.dart';
import '../theme.dart';
import 'code_view.dart';
import 'media_view.dart';
import 'mermaid_view.dart';

/// Assistant Markdown: prose through flutter_markdown, fenced code through
/// [CodeView], mermaid blocks through [MermaidView].
class AssistantBody extends StatelessWidget {
  const AssistantBody(this.text, {super.key, this.renderMermaid = true});
  final String text;

  /// Off in widget tests, where there is no WebView platform.
  final bool renderMermaid;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sheet = MarkdownStyleSheet.fromTheme(t).copyWith(
      p: t.textTheme.bodyLarge,
      a: TextStyle(color: t.colorScheme.onSurface, decoration: TextDecoration.underline),
      // A tighter line box than the prose, so the fill doesn't touch the lines above and below.
      code: TextStyle(
          fontFamily: fontMono, fontSize: 13.5, height: 1.2, backgroundColor: t.colorScheme.surfaceContainerHighest),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: t.colorScheme.outline, width: 3)),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final seg in splitFences(text))
        if (seg.isMermaid && renderMermaid)
          MermaidView(seg.body)
        else if (seg.isCode)
          CodeView(seg.body, language: seg.language)
        else
          MarkdownBody(
            data: seg.body,
            selectable: true,
            styleSheet: sheet,
            onTapLink: (text, href, title) {
              final uri = href == null ? null : Uri.tryParse(href);
              if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
    ]);
  }
}

class UserBubble extends StatelessWidget {
  const UserBubble(this.text, {super.key, this.pending = false});
  final String text;
  final bool pending;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final (rest, media) = splitUploads(text);
    return Align(
      alignment: Alignment.centerRight,
      // 80% of the chat's own width (a window's width counts the sidebar and the dock).
      child: LayoutBuilder(builder: (context, box) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: box.maxWidth * 0.8),
        child: Opacity(
          opacity: pending ? 0.55 : 1,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (media.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                  for (final (i, p) in media.indexed)
                    MediaTile(p,
                        size: media.length == 1 ? 180 : 112,
                        onOpen: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => MediaViewer(paths: media, initial: i)))),
                ]),
              ),
            if (rest.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
                child: SelectableText(rest, style: Theme.of(context).textTheme.bodyLarge),
              )
            else
              const SizedBox(height: 6),
          ]),
        ),
      )),
    );
  }
}

class NoteLine extends StatelessWidget {
  const NoteLine(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
      );
}

/// Consecutive tool calls in one hairline card. While any run they're listed,
/// with a button below that reveals the finished ones; once all are done the
/// card folds to a count. Tap a call for its input and output. A lone call is
/// just its row.
class ToolGroup extends StatefulWidget {
  const ToolGroup(this.calls, {super.key, this.fetchFull});
  final List<ToolCall> calls;

  /// Restores a call the cache cut short.
  final Future<void> Function(ToolCall)? fetchFull;
  @override
  State<ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<ToolGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final calls = widget.calls;
    final running = calls.where((c) => !c.done).toList();
    final finished = calls.length - running.length;
    final failed = calls.where((c) => c.isError).length;
    final shown = _open || calls.length == 1 ? calls : running;
    final title = running.isEmpty
        ? '${calls.length} tool calls'
        : _open
            ? 'Hide $finished finished'
            : 'Show $finished finished';
    final toggle = Semantics(
      button: true,
      expanded: _open,
      label: [title, if (failed > 0) '$failed failed'].join(', '),
      onTap: () => setState(() => _open = !_open),
      excludeSemantics: true,
      child: InfoBar(
        onTap: () => setState(() => _open = !_open),
        trailing: Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: k.muted),
        child: Text.rich(TextSpan(style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: k.ink), children: [
          TextSpan(text: title),
          // Folding must not hide that something failed.
          if (failed > 0) TextSpan(text: ' · $failed failed', style: TextStyle(color: k.removed)),
        ])),
      ),
    );
    final hasToggle = calls.length > 1 && finished > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: kEaseOut,
        alignment: Alignment.topCenter,
        child: Material(
          color: k.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (hasToggle && running.isEmpty) toggle,
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0 || (hasToggle && running.isEmpty)) Divider(color: k.divider),
              ToolRow(shown[i], key: ValueKey(shown[i].id), fetchFull: widget.fetchFull),
            ],
            if (hasToggle && running.isNotEmpty) ...[Divider(color: k.divider), toggle],
          ]),
        ),
      ),
    );
  }
}

/// A tappable row with a fold chevron.
class _FoldRow extends StatelessWidget {
  const _FoldRow({required this.label, required this.expanded, required this.onTap, required this.child});
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        expanded: expanded,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: RowTile(
          minHeight: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          onTap: onTap,
          trailing: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: Tokens.of(context).muted),
          child: child,
        ),
      );
}

/// READ src/a.ts · 212 lines, or a spinner while it runs.
class _ToolSummary extends StatelessWidget {
  const _ToolSummary(this.call);
  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final c = call;
    return Row(children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 44, maxWidth: 88),
        child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(c.verb,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 11, color: c.isError ? k.removed : k.muted, weight: FontWeight.w500)),
        ),
      ),
      Expanded(
        child: c.done
            ? Text(_shortPath(c.target),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.ink))
            : ShimmerText(_shortPath(c.target), style: TextStyle(fontSize: 13, color: k.ink)),
      ),
      const SizedBox(width: 8),
      if (!c.done)
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(c.shortResult,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.isError ? k.removed : k.muted)),
        ),
    ]);
  }
}

/// One folded tool call.
class ToolRow extends StatefulWidget {
  const ToolRow(this.call, {super.key, this.fetchFull});
  final ToolCall call;
  final Future<void> Function(ToolCall)? fetchFull;
  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;
  bool _fetching = false;

  Future<void> _toggle() async {
    setState(() => _open = !_open);
    final c = widget.call, fetch = widget.fetchFull;
    if (!_open || !c.clipped || fetch == null || _fetching) return;
    setState(() => _fetching = true);
    try {
      await fetch(c);
    } catch (_) {/* stays clipped and says so; opening it again retries */} finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final c = widget.call;
    final body = [
      _inputText(c),
      if (c.result != null && c.result!.isNotEmpty) _clip(c.result!),
      if (c.clipped && !_fetching) '… the rest is on the host. Close and reopen this to load it.',
    ].where((x) => x.isNotEmpty).join('\n\n');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _FoldRow(
        label: '${c.name} ${c.target}, ${c.shortResult}',
        expanded: _open,
        onTap: _toggle,
        child: _ToolSummary(c),
      ),
      if (_open && _fetching) const LinearProgressIndicator(minHeight: 2),
      if (_open && body.isNotEmpty)
        // A tap anywhere on the output folds it; a long press selects text.
        GestureDetector(
          onTap: _toggle,
          child: Container(
            color: k.termBg,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SelectableText(body,
                onTap: _toggle, style: mono(context, size: 11, color: k.termFg).copyWith(height: 1.5)),
          ),
        ),
    ]);
  }

  static String _clip(String s) => s.length > 20000 ? '${s.substring(0, 20000)}\n…' : s;

  static String _inputText(ToolCall c) => switch (c.name) {
        'Bash' => '\$ ${c.input['command'] ?? ''}',
        'Edit' => '- ${c.input['old_string'] ?? ''}\n+ ${c.input['new_string'] ?? ''}',
        'Write' => '${c.input['content'] ?? ''}'.length > 4000
            ? '${'${c.input['content']}'.substring(0, 4000)}\n…'
            : '${c.input['content'] ?? ''}',
        'Read' => '',
        _ => c.input.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
      };
}

/// "…/lib/ui/chat_screen.dart" for long paths.
String _shortPath(String s) {
  if (!s.startsWith('/') || s.length <= 42) return s;
  final parts = s.split('/');
  return parts.length <= 3 ? s : '…/${parts.sublist(parts.length - 3).join('/')}';
}

/// A file the agent wrote or edited, as a tile; tap opens it read-only.
class ArtifactTile extends StatelessWidget {
  const ArtifactTile({super.key, required this.path, required this.onOpen, this.changes});
  final String path;
  final VoidCallback onOpen;

  /// Lines added and removed.
  final (int, int)? changes;

  static String kindOf(String path) => switch (path.split('.').last.toLowerCase()) {
        'md' || 'markdown' || 'mdx' || 'txt' => 'Document',
        'html' || 'htm' => 'Page',
        'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => 'Image',
        _ => 'Code',
      };

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final name = path.split('/').last;
    final ext = name.contains('.') ? '.${name.split('.').last.toLowerCase()}' : '';
    final c = changes;
    return Semantics(
      button: true,
      label: 'Open $name, ${kindOf(path)}${c == null ? '' : ', ${c.$1} lines added, ${c.$2} removed'}',
      onTap: onOpen,
      excludeSemantics: true,
      child: Panel(
        onTap: onOpen,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: SizedBox(
          width: 148,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Row(children: [
                  // A blank page with a dashed edge and the file's extension.
                  CustomPaint(
                    painter: DashedBorder(k.faint, radius: 4, width: 1, dash: 3, gap: 2),
                    child: SizedBox(
                      width: 28,
                      height: 36,
                      child: Center(
                        child: Text(ext.length > 5 ? '' : ext,
                            style: mono(context, size: 8), maxLines: 1, overflow: TextOverflow.clip),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child:
                        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(name,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3),
                          overflow: TextOverflow.ellipsis),
                      if (c != null && (c.$1 > 0 || c.$2 > 0))
                        DeltaText(c.$2 == 0 ? '+${c.$1}' : '+${c.$1} −${c.$2}')
                      else
                        Text('new · ${kindOf(path)}', style: TextStyle(fontSize: 12, color: k.muted, height: 1.3)),
                    ]),
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}

/// Whether chat motion runs: off in tests (see [animateStatusSpinners]) and
/// when the system asks for less motion.
bool chatMotion(BuildContext context) => animateStatusSpinners && !MediaQuery.of(context).disableAnimations;

/// A new row easing into the conversation: it fades in while it grows from
/// nothing, so the messages above glide up instead of jumping.
class Appear extends StatefulWidget {
  const Appear({super.key, required this.animate, required this.child});

  /// False for history: it's simply there.
  final bool animate;
  final Widget child;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  // A new message, tens a day: under 300ms, on the app's ease-out.
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final _grow = CurvedAnimation(parent: _c, curve: kEaseOut);
  late final _fade = CurvedAnimation(parent: _c, curve: const Interval(0.2, 1, curve: kEaseOut));

  @override
  void initState() {
    super.initState();
    if (widget.animate && animateStatusSpinners) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        chatMotion(context) ? _c.forward() : _c.value = 1;
      });
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
        sizeFactor: _grow,
        alignment: Alignment.topCenter,
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(_grow),
            child: widget.child,
          ),
        ),
      );
}

/// Text with a soft highlight sweeping across it, for what's running now.
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  void _sync() {
    if (chatMotion(context) && windowActive.value) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    windowActive.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    chatMotion(context) && windowActive.value ? _c.repeat() : _c.stop();
  }

  @override
  void dispose() {
    windowActive.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
    if (!_c.isAnimating) return text;
    final base = widget.style.color ?? Tokens.of(context).ink;
    return RepaintBoundary(child: AnimatedBuilder(
      animation: _c,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) {
          // A bright band travels left to right across dimmed text.
          final x = -0.5 + _c.value * 2;
          return LinearGradient(
            colors: [base.withValues(alpha: 0.45), base, base.withValues(alpha: 0.45)],
            stops: [(x - 0.25).clamp(0.0, 1.0), x.clamp(0.0, 1.0), (x + 0.25).clamp(0.0, 1.0)],
          ).createShader(r);
        },
        child: child,
      ),
      child: text,
    ));
  }
}

/// "Reading router.ts", "Running npm test", "Thinking": what the agent is
/// doing, from the call that's running ([running] null: between calls).
String activityLabel(ToolCall? running) {
  if (running == null) return 'Thinking';
  final what = _shortPath(running.target).split('/').last;
  final verb = switch (running.name) {
    'Read' => 'Reading',
    'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => 'Editing',
    'Bash' || 'BashOutput' => 'Running',
    'Grep' || 'Glob' => 'Searching',
    'WebFetch' => 'Fetching',
    'WebSearch' => 'Searching the web for',
    'Task' || 'Agent' => 'Delegating',
    'TodoWrite' => 'Planning',
    final n => 'Using ${n.split('__').last}',
  };
  return what.isEmpty || running.name == 'TodoWrite' ? verb : '$verb $what';
}

/// The agent at work, under the last message: the thinking dots and what
/// it's doing ("Editing Pricing.svelte…"), shimmering.
/// The reply being written, taken from the agent's terminal: muted italic plain text in a dashed, tinted
/// bubble with a "writing…" label. It reuses the working line's dots as its only motion.
class WritingPreview extends StatelessWidget {
  const WritingPreview(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      liveRegion: true,
      label: 'Writing: $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: CustomPaint(
          painter: DashedBorder(k.faint, radius: kRadius),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(color: k.muted.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(kRadius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ThinkingDots(color: k.added),
                const SizedBox(width: 8),
                Text('writing…', style: TextStyle(fontSize: 12, color: k.muted)),
              ]),
              const SizedBox(height: 6),
              Text(text, style: TextStyle(fontSize: 14, height: 1.4, fontStyle: FontStyle.italic, color: k.muted)),
            ]),
          ),
        ),
      ),
    );
  }
}

class WorkingLine extends StatelessWidget {
  const WorkingLine(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Semantics(
      liveRegion: true,
      label: '$label…',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          ThinkingDots(color: k.added),
          const SizedBox(width: 8),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: kEaseOut,
              switchOutCurve: kEaseOut,
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, if (current != null) current]),
              child: ShimmerText('$label…', key: ValueKey(label), style: TextStyle(fontSize: 13, color: k.muted)),
            ),
          ),
        ]),
      ),
    );
  }
}
