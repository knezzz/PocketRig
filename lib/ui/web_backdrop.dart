import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' show Color;
import 'package:webview_flutter/webview_flutter.dart';

/// Sets the page's backdrop (what shows where a page sets no background). macOS's WebView has no such call: the plugin throws
/// 'opaque is not implemented on macOS', so there the page's own colours decide (a dark page comes from its colour-scheme).
/// A styling call never fails the page it styles.
Future<void> setWebBackdrop(WebViewController c, Color color) async {
  if (defaultTargetPlatform == TargetPlatform.macOS) return;
  try {
    await c.setBackgroundColor(color);
  } catch (_) {/* no backdrop: the page still shows */}
}
