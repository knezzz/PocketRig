import '../api/openrig_client.dart';
import '../models.dart';
import '../ssh/ssh_exec.dart';
import 'rig_spec.dart';

/// A running rig's spec and its text.
typedef LocatedSpec = ({RigSpecFile file, String text});

/// Finds the spec [rig] runs from: the file OpenRig launched it from (its
/// launch record, which may be outside the project, like
/// `~/.openrig/specs/<rig>/rig.yaml`), else a spec named like the rig in
/// [cwd], its seats' folder. Null when neither has one.
Future<LocatedSpec?> locateRigSpec(SshExec ssh, OpenRigClient api, Rig rig, String? cwd) async {
  String? launched;
  try {
    launched = await api.rigSpecSource(rig.id);
  } catch (_) {/* no launch record: look in the folder */}
  if (launched != null) {
    final text = await ssh.readFile(launched);
    // readFile is empty for a file that has since moved or been deleted.
    if (text.trim().isNotEmpty) return (file: RigSpecFile(path: launched, projectPath: cwd ?? launched), text: text);
  }
  if (cwd == null) return null;
  for (final f in await ssh.findRigSpecs(cwd)) {
    final text = await ssh.readFile(f.path);
    if (RigSpecSummary.parse(text).name == rig.name) return (file: f, text: text);
  }
  return null;
}

/// Why [locateRigSpec] came back empty, naming where it looked.
String specNotFound(Rig rig, String? launched, String? cwd) => [
      'Couldn\'t find ${rig.name}\'s spec.',
      launched != null
          ? 'It was launched from ${displayPath(launched)}, which is gone.'
          : 'OpenRig has no launch record for it.',
      if (cwd != null) 'No spec named ${rig.name} in ${displayPath(cwd)} either.',
    ].join(' ');
