import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/git_status.dart';
import '../../data/rig_spec.dart';
import '../../models.dart';
import '../../ssh/ssh_exec.dart';
import '../common.dart';
import '../kit.dart';
import '../launch_sheet.dart' show worktreeRigName;
import '../spec_screen.dart';

class SpecEntry {
  SpecEntry(this.file, this.text) : summary = RigSpecSummary.parse(text);
  final RigSpecFile file;
  final String text;
  final RigSpecSummary summary;
}

/// Each folder on its own, so a blocked project folder doesn't hide a connected one's specs: the rig specs under
/// [projectPath] and under the folder linked to it, read over [ssh], and the first failure (null when none).
Future<(List<SpecEntry>, Object?)> readSpecs(SshExec ssh, Host host, String projectPath, String? absPath) async {
  final files = <String, RigSpecFile>{};
  Object? failed;
  try {
    for (final f in await ssh.findRigSpecs(projectPath)) {
      files[f.path] = f;
    }
  } catch (e) {
    failed = e;
  }
  final linked = host.specFolders[projectPath];
  if (linked != null) {
    try {
      for (final f in await ssh.findRigSpecs(linked)) {
        // Started from here, so the project stays the working folder.
        files[f.path] ??= RigSpecFile(path: f.path, projectPath: absPath ?? projectPath);
      }
    } catch (e) {
      failed ??= e;
    }
  }
  return ([for (final f in files.values) SpecEntry(f, await ssh.readFile(f.path))], failed);
}

/// What starting a rig in a project needs, read over SSH in one go: the worktrees and the grouped specs (and the
/// first failure reading them). A `~` project folder is resolved the way ProjectScreen does, so a linked spec folder's
/// specs keep the real folder as their project.
Future<(List<Worktree>, List<List<SpecEntry>>, Object?)> readForStart(Host host, String projectPath) async {
  final ssh = await SshExec.connect(host);
  try {
    final abs = projectPath.startsWith('~') ? await ssh.resolve(projectPath) : null;
    final worktrees = await ssh.worktrees(projectPath).catchError((_) => <Worktree>[]);
    final (entries, failed) = await readSpecs(ssh, host, projectPath, abs != null && abs.isNotEmpty ? abs : null);
    return (worktrees, groupSpecs(entries), failed);
  } finally {
    ssh.close();
  }
}

/// Starts a rig in a project (its main checkout, or the worktree at [worktreePath]) from anywhere (a ⋯ list): reads its specs, picks one (the only one is
/// taken as is), and opens the launch sheet with [push]. The same flow as the project page's Start rig.
Future<void> startRigInProject(BuildContext context, Host host, String projectPath, String projectName,
    {required void Function(Widget) push, String? worktreePath}) async {
  final List<Worktree> worktrees;
  final List<List<SpecEntry>> groups;
  final Object? failed;
  try {
    (worktrees, groups, failed) = await readForStart(host, projectPath);
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t list specs over SSH: $e', kind: ToastKind.problem);
    return;
  }
  if (!context.mounted) return;
  if (!groups.any((c) => c.any((s) => s.summary.error == null))) {
    toast(context, failed != null ? 'Couldn\'t list specs over SSH: $failed' : 'No rig specs in this project.',
        kind: ToastKind.info);
    return;
  }
  // The checkout to start in: [worktreePath], else the main checkout.
  final w = worktrees.where((w) => w.path == worktreePath).firstOrNull ?? worktrees.firstOrNull ?? Worktree(projectPath, null);
  await startRigInWorktree(context,
      w: w,
      main: worktrees.isEmpty || identical(w, worktrees.first),
      projectName: projectName,
      specGroups: groups,
      worktrees: worktrees,
      push: push);
}

/// One group per spec: its copies across the main checkout and the worktrees, the main checkout's first.
List<List<SpecEntry>> groupSpecs(List<SpecEntry> specs) {
  final byPath = <String, List<SpecEntry>>{};
  for (final s in specs) {
    byPath.putIfAbsent(s.file.checkoutPath, () => []).add(s);
  }
  final paths = byPath.keys.toList()..sort();
  return [
    for (final p in paths)
      byPath[p]!
        ..sort((a, b) {
          final main = (a.file.worktree == null ? 0 : 1) - (b.file.worktree == null ? 0 : 1);
          return main != 0 ? main : a.file.path.compareTo(b.file.path);
        }),
  ];
}

/// Starts a rig in worktree [w]: picks a spec when there are several, using that worktree's copy when it has one,
/// then opens the launch sheet (the spec's preview) with [w]'s path filled in. Outside the main checkout the rig
/// gets the worktree in its name so it can run beside the main one.
Future<void> startRigInWorktree(BuildContext context,
    {required Worktree w,
    required bool main,
    required String projectName,
    required List<List<SpecEntry>> specGroups,
    required List<Worktree> worktrees,
    required void Function(Widget) push}) async {
  final groups = specGroups.where((c) => c.any((s) => s.summary.error == null)).toList();
  String name(List<SpecEntry> c) => c.first.summary.name ?? c.first.file.checkoutPath;
  final copies = groups.length == 1
      ? groups.single
      : await showModalBottomSheet<List<SpecEntry>>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                SectionLabel('Start in ${main ? 'Main checkout' : w.name}'),
                BorderedList(children: [
                  for (final c in groups)
                    RowTile(
                      title: name(c),
                      meta: c.first.file.checkoutPath,
                      metaMono: true,
                      trailing: const Chevron(),
                      onTap: () => Navigator.pop(ctx, c),
                    ),
                ]),
              ]),
            ),
          ),
        );
  if (copies == null || !context.mounted) return;
  final valid = copies.where((s) => s.summary.error == null);
  final spec = valid.where((s) => s.file.worktree == (main ? null : w.name)).firstOrNull ?? valid.first;
  push(SpecScreen(
    file: spec.file,
    text: spec.text,
    projectName: projectName,
    previewNow: true,
    cwd: w.path,
    rigName: main ? null : worktreeRigName(name(copies), w.name),
    worktrees: worktrees,
  ));
}
