import 'package:flutter/material.dart';

import '../data/fleet.dart';
import '../main.dart' show navigatorKey;
import '../models.dart';
import 'action_rows.dart';
import 'restore_all.dart';

/// The one ⋯ list for a host, whichever row asks. Rescan is the only manual rescan of what's running there.
ActionRows hostActionRows(Host host) => (
      items: [
        (
          Icons.refresh_outlined,
          'Rescan',
          'Look again for the agents running on ${host.name}',
          () => fleet.feedFor(host).refresh(scan: true).ignore()
        ),
        // One row per host that has stopped rigs, here and in ⌘K.
        if (stoppedRigs(host).length case final n when n > 0)
          (
            Icons.restore_outlined,
            'Restore all stopped rigs…',
            '$n stopped on ${host.name}',
            () {
              if (navigatorKey.currentContext case final c? when c.mounted) restoreAllStopped(c, host);
            }
          ),
      ],
      danger: const [],
    );

Future<void> showHostActions(BuildContext context, Host host) =>
    showActionRows(context, host.name, hostActionRows(host));
