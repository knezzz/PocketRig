import 'package:flutter/foundation.dart';

/// What is being done right now, by key (a rig id, a folder path): one set for every trigger, so a second tap
/// from the ⋯, a long press or the sidebar can't start the same work twice, and a row can show it's busy.
final busyKeys = ValueNotifier<Set<String>>(const {});

/// Runs [body] unless [key] is already busy; the key is busy until it finishes, however it ends.
Future<void> exclusive(String key, Future<void> Function() body) async {
  if (busyKeys.value.contains(key)) return;
  busyKeys.value = {...busyKeys.value, key};
  try {
    await body();
  } finally {
    busyKeys.value = {...busyKeys.value}..remove(key);
  }
}
