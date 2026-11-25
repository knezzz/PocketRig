import 'package:flutter/material.dart';

import 'theme.dart';

/// The one thin bar above a chat's messages: the git line and a tool-call group's "N tool calls" fold share its height,
/// fill and padding. A null [onTap] makes it a plain strip.
class InfoBar extends StatelessWidget {
  const InfoBar({super.key, required this.child, this.onTap, this.trailing});
  final Widget child;
  final VoidCallback? onTap;
  final Widget? trailing;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) => Material(
        color: Tokens.of(context).headerFill,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                Expanded(child: child),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ]),
            ),
          ),
        ),
      );
}
