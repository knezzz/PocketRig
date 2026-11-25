import '../models.dart';
import 'projects.dart' show shQuote;

/// A Claude Code dialog (permission, question, trust) has numbered choices (`❯ 1. Yes`) or, without numbers, an
/// `Esc to cancel` footer. The watcher uses the same rule: change host/watcher/pocketrig-watcher.mjs together.
final _choice = RegExp(r'^\s*(?:❯\s*)?[1-9]\.\s+\S|\bEsc to cancel\b', multiLine: true);

/// Whether [screen], the visible text of a Claude pane, shows no dialog. An empty screen proves nothing. A numbered
/// list in the chat counts as a dialog: that only keeps the daemon's word.
bool noDialogOnScreen(String screen) => screen.trim().isNotEmpty && !_choice.hasMatch(screen);

/// A real dialog, for the send guard: the option under the cursor (`❯ 1.`) or the `Esc to cancel` footer. A numbered list in
/// the agent's own output ('1. Fix x') is not one, or ordinary replies would stop every message.
final _realDialog = RegExp(r'^\s*❯\s*[1-9]\.\s+\S|\bEsc to cancel\b', multiLine: true);

/// [_realDialog] as the extended regex `grep -E` takes, for scripts that look at a pane on the host (the Auto switch): one rule in
/// two syntaxes, tested against the same fixture panes. Bytes only, so it works under a shell with no UTF-8 locale.
const realDialogGrep = r'^[[:space:]]*❯[[:space:]]*[1-9]\.[[:space:]]+[^[:space:]]|Esc to cancel';

/// Whether [screen] shows a Claude dialog (a permission prompt, an AskUserQuestion menu, the trust dialog), by the stricter
/// [_realDialog] rule; an empty screen answers no. [noDialogOnScreen] is the watcher's rule and leans the other way on purpose.
bool dialogOnScreen(String screen) => screen.trim().isNotEmpty && _realDialog.hasMatch(screen);

/// Each session's screen text in [out] ([screensScript]'s output), by session name.
Map<String, String> screensBySession(String out) => {
      for (final c in out.split('@@screen\t').skip(1))
        if (c.indexOf('\n') case final nl when nl > 0) c.substring(0, nl): c.substring(nl + 1),
    };

/// The daemon holds a Claude permission or question ask until its turn ends when it never saw the dialog on screen
/// (a subagent's, answered by auto mode), so a seat can say "needs you" for as long as it works. Only those two
/// reasons have a dialog to look for.
bool asksWithDialog(Seat s) =>
    s.daemonAsks &&
    s.isClaude &&
    s.sessionName != null &&
    (s.needsInputReason == 'permission_prompt' || s.needsInputReason == 'selection_prompt');

/// Each session's visible screen, after `@@screen<TAB>name`.
String screensScript(Iterable<String> sessions) =>
    [for (final s in sessions) "printf '@@screen\\t%s\\n' ${shQuote(s)}; tmux capture-pane -p -t ${shQuote('=$s:')} 2>/dev/null"]
        .join('; ');

/// The sessions in [out] ([screensScript]'s output) whose screen shows no dialog.
Set<String> sessionsWithoutDialog(String out) => {
      for (final c in out.split('@@screen\t').skip(1))
        if (c.indexOf('\n') case final nl when nl > 0)
          if (noDialogOnScreen(c.substring(nl + 1))) c.substring(0, nl),
    };
