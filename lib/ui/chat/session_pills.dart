import 'package:flutter/material.dart';
import '../theme.dart';

/// The chat's side inset: the transcript, the session pills and the permission card above the composer all start 20 in, so
/// their edges line up.
const chatGutter = 20.0;

/// The row of pills over the composer.
class SessionPills extends StatelessWidget {
  const SessionPills({super.key, required this.pills});
  final List<Widget> pills;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Container(
      decoration: BoxDecoration(color: k.ground, border: Border(top: BorderSide(color: k.divider))),
      padding: const EdgeInsets.fromLTRB(chatGutter, 8, chatGutter, 0),
      height: 38,
      child: Semantics(
        container: true,
        label: 'Session',
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: pills.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) => pills[i],
        ),
      ),
    );
  }
}

/// One session chip: a status shape or icon, a name or count, and for files
/// the diff in git colors. State colors tint it (mint subagents, cyan
/// shells); files, PRs and media stay grey.
class SessionPill extends StatelessWidget {
  const SessionPill({
    super.key,
    this.icon,
    this.leading,
    required this.label,
    required this.spoken,
    required this.onTap,
    this.added,
    this.removed,
    this.tint,
    this.textColor,
    this.bold = false,
  });
  final IconData? icon;

  /// In place of [icon]: a status shape or a ✓.
  final Widget? leading;
  final String label;
  final String spoken;
  final VoidCallback onTap;
  final int? added;
  final int? removed;

  /// The chip's fill; grey when null.
  final Color? tint;
  final Color? textColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final fg = textColor ?? k.ink;
    final lead = leading ?? (icon == null ? null : Icon(icon, size: 14, color: textColor ?? k.muted));
    return Semantics(
      button: true,
      label: '$spoken${added != null ? ', $added lines added, $removed removed' : ''}',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: tint ?? k.fill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (lead != null) ...[lead, const SizedBox(width: 6)],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w600 : FontWeight.w500, color: fg)),
              ),
              if (added != null) ...[
                const SizedBox(width: 6),
                Text('+$added', style: mono(context, size: 11, color: k.added, weight: FontWeight.w500)),
                const SizedBox(width: 4),
                Text('−$removed', style: mono(context, size: 11, color: k.removed, weight: FontWeight.w500)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
