import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/data/rig_spec.dart';
import 'package:pocket_rig/data/rig_spec_edit.dart';

import 'rig_spec_test.dart' show pmSpec;

void main() {
  test('parses how each seat runs: role, model, effort, permissions', () {
    final s = RigSpecSummary.parse('''
version: "0.2"
name: t
permission_policy: builtin:standard
culture_file: CULTURE.md
pods:
  - id: dev
    label: Dev
    members:
      - id: lead
        runtime: claude-code
        role: lead
        model: claude-opus-5-5
        effort: high
        permission_policy: builtin:open
        claude_permissions:
          allow: ["Bash(npm run *)", Read]
          deny: [WebFetch]
    edges:
      - {kind: delegates_to, from: lead, to: lead}
''');
    expect(s.permissionPolicy, 'builtin:standard');
    expect(s.cultureFile, 'CULTURE.md');
    final m = s.pods.single.members.single;
    expect(m.role, 'lead');
    expect(m.model, 'claude-opus-5-5');
    expect(m.effort, 'high');
    expect(m.permissionPolicy, 'builtin:open');
    expect(m.claudePermissions, {'allow': ['Bash(npm run *)', 'Read'], 'deny': ['WebFetch']});
    expect(m.oneLine, 'Claude Code · claude-opus-5-5 · high effort · open');
    expect(s.qualifiedIds, ['dev.lead']);
    expect(s.edges.single.pod, 0);
    expect(s.edges.single.index, 0);
  });

  test('member and rig fields round-trip, keeping comments outside the rewritten section; empty removes', () {
    final ed = RigSpecEditor('''
version: "0.2"
name: pm # the name
pods:
  - id: pm
    label: PM
    members:
      - id: lead
        runtime: claude-code   # keep me
''');
    ed.updateMember(0, 0, {'model': 'claude-opus-5-5', 'effort': 'high', 'role': 'lead', 'permission_policy': 'builtin:open'});
    ed.setRigField('summary', 'A rig');
    var m = ed.spec.pods.single.members.single;
    expect(m.model, 'claude-opus-5-5');
    expect(m.effort, 'high');
    expect(m.role, 'lead');
    expect(ed.spec.summary, 'A rig');
    expect(ed.text, contains('name: pm # the name'), reason: 'lines outside pods are untouched');
    expect(ed.text, contains('version: "0.2"'));

    ed.updateMember(0, 0, {'model': '', 'effort': null});
    ed.setRigField('summary', '');
    m = ed.spec.pods.single.members.single;
    expect(m.model, isNull);
    expect(m.effort, isNull);
    expect(m.role, 'lead');
    expect(ed.spec.summary, isNull);
    // Removing something that isn't there is fine.
    ed.updateMember(0, 0, {'effort': null});
    expect(RigSpecSummary.parse(ed.text).error, isNull);
  });

  test('claude tool rules are written as lists and removed when emptied', () {
    final ed = RigSpecEditor(pmSpec);
    ed.updateMember(0, 0, {
      'claude_permissions': {'allow': ['Bash(npm run *)', 'Read'], 'deny': ['WebFetch']},
    });
    expect(ed.spec.pods.first.members.first.claudePermissions['allow'], ['Bash(npm run *)', 'Read']);
    ed.updateMember(0, 0, {'claude_permissions': null});
    expect(ed.spec.pods.first.members.first.claudePermissions, isEmpty);
    expect(ed.text, isNot(contains('claude_permissions')));
  });

  test('departments and roles can be added, in block style, and removed with their edges', () {
    final ed = RigSpecEditor(pmSpec);
    ed.addPod(id: 'qa', label: 'QA');
    expect(ed.spec.pods.map((p) => p.id), ['pm', 'dev', 'qa']);
    ed.addMember(2, {'id': 'tests', 'runtime': 'codex', 'model': '', 'effort': null});
    ed.addMember(2, {'id': 'smoke', 'runtime': 'claude-code'});
    expect(ed.spec.pods[2].members.map((m) => m.id), ['tests', 'smoke']);
    expect(ed.text, isNot(contains('[{')), reason: 'new members are written as block maps');
    expect(ed.text, isNot(contains('model:')), reason: 'blank fields are left out');

    ed.addEdge('pm.lead', 'delegates_to', 'qa.tests');
    expect(ed.spec.edges.map((e) => '${e.from}>${e.to}'), contains('pm.lead>qa.tests'));
    ed.removeMember(2, 0);
    expect(ed.spec.pods[2].members.map((m) => m.id), ['smoke']);
    expect(ed.spec.edges.map((e) => e.to), isNot(contains('qa.tests')));

    ed.removePod(1); // dev, which pm.lead delegates to at rig level
    expect(ed.spec.pods.map((p) => p.id), ['pm', 'qa']);
    expect(ed.spec.edges.map((e) => e.to), isNot(contains('dev.build')));
    expect(ed.spec.edges.map((e) => '${e.from}>${e.to}'), ['pm.lead>pm.researcher']);
  });

  test('renaming a role or a department rewrites the relationships that name it', () {
    final ed = RigSpecEditor(pmSpec);
    ed.updateMember(0, 0, {'id': 'chief'});
    expect(ed.spec.edges.map((e) => '${e.from}>${e.to}'), ['pm.chief>pm.researcher', 'pm.chief>dev.build']);
    ed.updatePod(1, id: 'eng', label: 'Engineering');
    expect(ed.spec.pods[1].label, 'Engineering');
    expect(ed.spec.edges.map((e) => '${e.from}>${e.to}'), ['pm.chief>pm.researcher', 'pm.chief>eng.build']);
    expect(RigSpecSummary.parse(ed.text).error, isNull);
  });

  test('a relationship inside one department is pod-local; across departments it is rig-level', () {
    final ed = RigSpecEditor(pmSpec);
    ed.addEdge('pm.researcher', 'escalates_to', 'pm.lead');
    final local = ed.spec.edges.firstWhere((e) => e.kind == 'escalates_to');
    expect(local.pod, 0);
    expect(ed.text, contains('from: researcher\n'));
    ed.addEdge('dev.build', 'collaborates_with', 'pm.researcher');
    final cross = ed.spec.edges.firstWhere((e) => e.kind == 'collaborates_with');
    expect(cross.pod, isNull);
    expect(ed.text, contains('from: dev.build'));

    // Changing ends moves it between the lists.
    ed.updateEdge(cross, from: 'pm.lead', kind: 'can_observe', to: 'pm.researcher');
    expect(ed.spec.edges.where((e) => e.kind == 'collaborates_with'), isEmpty);
    expect(ed.spec.edges.firstWhere((e) => e.kind == 'can_observe').pod, 0);
    ed.removeEdge(ed.spec.edges.firstWhere((e) => e.kind == 'can_observe'));
    expect(ed.spec.edges.where((e) => e.kind == 'can_observe'), isEmpty);
    expect(RigSpecSummary.parse(ed.text).error, isNull);
  });

  test('a spec with no pods or edges yet gets them', () {
    final ed = RigSpecEditor('version: "0.2"\nname: fresh\n');
    ed.addPod(id: 'core', label: 'Core');
    ed.addMember(0, {'id': 'a', 'runtime': 'claude-code'});
    ed.addMember(0, {'id': 'b', 'runtime': 'codex'});
    ed.addEdge('core.a', 'delegates_to', 'core.b');
    final s = ed.spec;
    expect(s.pods.single.members.length, 2);
    expect(s.edges.single.pod, 0);
    expect(s.error, isNull);
  });

  const rich = '''
version: "0.2"
name: rich # keep this comment
x_future: {a: 1}
startup:
  files:
    - path: guidance/team.md
pods:
  - id: dev
    label: Dev
    x_pod_future: kept
    members:
      - id: build
        runtime: claude-code
        x_member_future: [1, 2]
        env:
          LOG_LEVEL: info
''';

  test('a switch, an enum, an env map and a YAML block can each be set and cleared; unknown fields survive', () {
    final ed = RigSpecEditor(rich);
    // scalar switch (rig)
    ed.setRigValue('non_interruptive', true);
    expect(ed.rigValue('non_interruptive'), true);
    expect(ed.text, contains('non_interruptive: true'));
    ed.setRigValue('non_interruptive', null);
    expect(ed.rigValue('non_interruptive'), isNull);
    expect(ed.text, isNot(contains('non_interruptive')));
    // enum (member)
    ed.updateMember(0, 0, {'restore_policy': 'relaunch_fresh', 'compaction_strategy': 'handover'});
    expect(ed.memberValue(0, 0, 'restore_policy'), 'relaunch_fresh');
    ed.updateMember(0, 0, {'restore_policy': null});
    expect(ed.memberValue(0, 0, 'restore_policy'), isNull);
    expect(ed.memberValue(0, 0, 'compaction_strategy'), 'handover');
    // env map (rig, and a member's own is replaced whole)
    ed.setRigValue('env', envMap([('REGION', 'eu'), ('', ''), ('LOG_LEVEL', ' debug ')]));
    expect(ed.rigValue('env'), {'REGION': 'eu', 'LOG_LEVEL': 'debug'});
    ed.updateMember(0, 0, {'env': envMap([('LOG_LEVEL', 'warn')])});
    expect(ed.memberValue(0, 0, 'env'), {'LOG_LEVEL': 'warn'});
    ed.setRigValue('env', <String, String>{});
    expect(ed.rigValue('env'), isNull, reason: 'an empty map is removed');
    // nested YAML block (pod startup, member codex_permissions)
    final block = parseYamlBlock('files:\n  - path: guidance/dev.md\n    required: true\nactions: []');
    ed.updatePodFields(0, {'startup': block, 'summary': 'Build things'});
    expect(ed.podValue(0, 'startup'), {'files': [{'path': 'guidance/dev.md', 'required': true}], 'actions': []});
    expect(ed.podValue(0, 'summary'), 'Build things');
    expect(yamlBlockText(ed.podValue(0, 'startup')), contains('path: guidance/dev.md'));
    ed.updatePodFields(0, {'startup': null});
    expect(ed.podValue(0, 'startup'), isNull);
    expect(ed.podValue(0, 'summary'), 'Build things');
    // rig-level block too
    ed.setRigValue('services', parseYamlBlock('kind: compose\ncompose_file: docker-compose.yaml'));
    expect(ed.rigValue('services'), {'kind': 'compose', 'compose_file': 'docker-compose.yaml'});
    ed.setRigValue('services', null);

    // Everything the editor never touched is still there, comments included.
    final out = ed.text;
    expect(out, contains('name: rich # keep this comment'));
    expect(out, contains('x_future'));
    expect(out, contains('x_pod_future: kept'));
    expect(out, contains('x_member_future'));
    expect(out, contains('guidance/team.md'), reason: 'the rig-level startup block');
    expect(out, isNot(contains('services')));
    expect(RigSpecSummary.parse(out).error, isNull);
  });

  test('env rows are checked against the rig-spec rules', () {
    expect(envError([('LOG_LEVEL', 'info'), ('_A1', 'x'), ('', '')]), isNull);
    expect(envError([('log', 'x')]), contains('isn\'t a valid name'));
    expect(envError([('1A', 'x')]), contains('isn\'t a valid name'));
    expect(envError([('OPENRIG_HOME', 'x')]), contains('reserved'));
    expect(envError([('REGION', ' ')]), contains('needs a value'));
    expect(envError([('REGION', 'eu'), ('REGION', 'us')]), contains('twice'));
  });

  test('a YAML block says why it does not parse, and blank means none', () {
    expect(parseYamlBlock('  \n'), isNull);
    expect(() => parseYamlBlock('a: [1, 2'), throwsFormatException);
    expect(parseYamlBlock('kind: compose'), {'kind': 'compose'});
    expect(yamlBlockText(null), '');
    expect(safeRelativePath('agents/a.md'), isTrue);
    expect(safeRelativePath('../a.md'), isFalse);
    expect(safeRelativePath('/abs/a.md'), isFalse);
  });

  test('a file that is not a map is refused', () {
    expect(() => RigSpecEditor('- a\n- b\n'), throwsFormatException);
  });
}
