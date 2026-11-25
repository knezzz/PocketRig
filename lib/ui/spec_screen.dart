import 'package:flutter/material.dart';

import '../data/git_status.dart';
import '../data/rig_spec.dart';
import '../models.dart';
import 'common.dart';
import 'kit.dart';
import 'theme.dart';
import 'launch_sheet.dart';
import 'rig/graph_layout.dart';
import 'rig/seat_graph.dart' show GraphLegend, SeatGraph, edgeLegend;
import 'spec_editor_screen.dart';

/// Inspect a RigSpec file and start a rig from it in the launch sheet.
class SpecScreen extends StatefulWidget {
  const SpecScreen({
    super.key,
    required this.file,
    required this.text,
    required this.projectName,
    this.previewNow = false,
    this.cwd,
    this.rigName,
    this.worktrees = const [],
    this.initialView = 0,
  });
  final RigSpecFile file;
  final String text;
  final String projectName;

  /// Opened from a Start button: open the launch sheet straight away.
  final bool previewNow;

  /// Prefills the working folder and rig name, e.g. to start a second copy in a worktree.
  final String? cwd;
  final String? rigName;

  /// The project's worktrees, main checkout first, offered on the launch sheet.
  final List<Worktree> worktrees;

  /// 0 Summary, 1 Graph, 2 YAML.
  final int initialView;

  @override
  State<SpecScreen> createState() => _SpecScreenState();
}

class _SpecScreenState extends State<SpecScreen> {
  late String _text = widget.text;
  late RigSpecSummary _spec = RigSpecSummary.parse(_text);
  late int _view = widget.initialView;

  @override
  void initState() {
    super.initState();
    if (widget.previewNow && _spec.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _launch();
      });
    }
  }

  void _launch() => showLaunchSheet(
        context,
        file: widget.file,
        spec: _spec,
        projectName: widget.projectName,
        worktrees: widget.worktrees,
        cwd: widget.cwd,
        rigName: widget.rigName,
      );

  /// The visual editor; it hands back the saved text.
  Future<void> _editSpec() async {
    final saved = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => SpecEditorScreen(file: widget.file, text: _text, projectName: widget.projectName),
    ));
    if (saved == null || !mounted) return;
    setState(() {
      _text = saved;
      _spec = RigSpecSummary.parse(saved);
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final valid = _spec.error == null;
    final where = [
      if (_spec.summary != null) _spec.summary!,
      [widget.file.relativePath, if (_spec.version != null) 'v${_spec.version}'].join(' · '),
    ].join(' · ');
    return Scaffold(
      body: Column(children: [
        PageHeader(
          overline: '${widget.projectName} · rig spec',
          title: _spec.name ?? widget.file.relativePath,
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(where, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted)),
            if (!valid) ...[
              const SizedBox(height: 2),
              Text('! Not a valid RigSpec', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: k.removed)),
            ],
          ]),
          actions: [
            IconButton(
              tooltip: 'Spec options',
              icon: const Icon(Icons.more_horiz),
              onPressed: () => showActionSheet(context, null, [
                (Icons.edit_outlined, 'Edit spec', null, valid ? _editSpec : null),
                (Icons.rocket_launch_outlined, 'Start rig…', null, valid ? _launch : null),
              ]),
            ),
          ],
          bottom: Segmented<int>(
            values: const [0, 1, 2],
            labels: const ['Summary', 'Graph', 'YAML'],
            selected: _view,
            onChanged: (v) => setState(() => _view = v),
            semanticLabel: 'Spec views',
          ),
        ),
        Expanded(
          child: _view == 1
              ? _Graph(spec: _spec)
              : _view == 2
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: k.termBg, borderRadius: BorderRadius.circular(kRadius)),
                    child:
                        SelectableText(_text, style: mono(context, size: 11, color: k.termFg).copyWith(height: 1.55)),
                  ),
                )
              : _Summary(file: widget.file, spec: _spec),
        ),
        // Starting it is the point of the screen: always in view (also in the ⋯ menu).
        KillBar(const [],
            primary: ('Start rig', Icons.rocket_launch_outlined, valid ? _launch : null),
            primaryNote: 'Not a valid RigSpec: fix it before starting a rig'),
      ]),
    );
  }
}

/// The spec's seats drawn like a running rig's Seats tab, before launch: the same legend, solid pods and seats, and a
/// tap on a link names it.
class _Graph extends StatefulWidget {
  const _Graph({required this.spec});
  final RigSpecSummary spec;

  @override
  State<_Graph> createState() => _GraphState();
}

class _GraphState extends State<_Graph> {
  GraphEdgeIn? _picked;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final spec = widget.spec;
    if (spec.error != null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        ErrorBanner('This file isn\'t a valid RigSpec: ${spec.error}', margin: EdgeInsets.zero),
      ]);
    }
    final input = [
      for (final p in spec.pods)
        for (final m in p.members) GraphNodeIn('${p.id}.${m.id}', m.id, p.label ?? p.id)
    ];
    final names = {for (final n in input) n.id: n.logicalId};
    // Not running yet: a stopped seat carrying what the spec sets, so nodes show the runtime logo, model and effort.
    final members = {for (final p in spec.pods) for (final m in p.members) '${p.id}.${m.id}': m};
    final edges = [for (final e in spec.edges) GraphEdgeIn(e.from, e.to, e.kind)];
    final kinds = {for (final e in edges) e.kind}.toList()..sort();
    final picked = _picked;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Padding(padding: const EdgeInsets.only(bottom: 12), child: GraphLegend(kinds: kinds)),
      LayoutBuilder(
        builder: (context, box) => SeatGraph(
          layout: GraphLayout.column(input, edges, box.maxWidth),
          names: names,
          solid: true,
          onEdge: (e) => setState(() => _picked = e),
          byId: {
            for (final MapEntry(:key, value: m) in members.entries)
              key: Seat(rigId: '', logicalId: m.id, runtime: m.runtime, model: m.model, effort: m.effort, rawSessionStatus: 'stopped')
          },
          lines: {
            for (final MapEntry(:key, value: m) in members.entries) key: m.role ?? SpecMember.runtimeLabel(m.runtime)
          },
          onTap: (_) {},
        ),
      ),
      if (picked != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('${names[picked.from] ?? picked.from}  ${edgeLegend(picked.kind)}  ${names[picked.to] ?? picked.to}',
              style: mono(context, size: 12, color: k.ink)),
        )
      else if (edges.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Tap a line to see what it links.', style: TextStyle(fontSize: 12, color: k.muted)),
        ),
    ]);
  }
}

class _Summary extends StatefulWidget {
  const _Summary({required this.file, required this.spec});
  final RigSpecFile file;
  final RigSpecSummary spec;

  @override
  State<_Summary> createState() => _SummaryState();
}

class _SummaryState extends State<_Summary> {
  /// Members whose agent reference (a long path) is showing: it is behind a tap.
  final _showRef = <String>{};

  RigSpecFile get file => widget.file;
  RigSpecSummary get spec => widget.spec;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    if (spec.error != null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        ErrorBanner('This file isn\'t a valid RigSpec: ${spec.error}', margin: EdgeInsets.zero),
      ]);
    }
    final pods = spec.pods.length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionLabel('Seats · ${spec.seatCount} in $pods pod${pods == 1 ? '' : 's'}'),
        BorderedList(children: [
          for (final pod in spec.pods) ...[
            Container(
              color: k.headerFill,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(pod.id.toUpperCase(), style: mono(context, size: 11, weight: FontWeight.w600)),
                // The pod's name once: a label that only repeats the id in another case is not shown.
                if (pod.label != null && pod.label!.toLowerCase() != pod.id.toLowerCase()) ...[
                  const SizedBox(width: 10),
                  Expanded(child: Text(pod.label!, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted))),
                ],
              ]),
            ),
            for (final m in pod.members)
              RowTile(
                minHeight: 52,
                leading: SizedBox(width: 32, height: 32, child: Center(child: RuntimeGlyph(m.runtime, size: 22))),
                title: m.role == null ? m.id : '${m.id} · ${m.role}',
                meta: m.oneLine,
                // The agent reference is a long path: it shows when the row is tapped.
                extra: _showRef.contains('${pod.id}.${m.id}') ? m.agentRef : null,
                onTap: m.agentRef == null
                    ? null
                    : () => setState(() {
                          final key = '${pod.id}.${m.id}';
                          _showRef.contains(key) ? _showRef.remove(key) : _showRef.add(key);
                        }),
              ),
          ],
        ]),
        if (spec.edges.isNotEmpty) ...[
          const SizedBox(height: 18),
          SectionLabel('Relationships · ${spec.edges.length}'),
          Panel(
            padding: const EdgeInsets.all(13), // the old box's 12 plus its 1 dp border
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final e in spec.edges)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: e.from, style: mono(context, size: 12, color: k.ink)),
                    TextSpan(text: '  ${e.kind} →  ', style: mono(context, size: 12, color: k.muted)),
                    TextSpan(text: e.to, style: mono(context, size: 12, color: k.ink)),
                  ])),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Text(displayPath(file.path), style: mono(context)),
      ],
    );
  }
}
