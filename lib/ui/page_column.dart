import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The widest a page body gets on a big window; headers and tab strips stay full width.
const pageColumnWidth = 880.0;

/// Centres a page's body in a column of [pageColumnWidth] when the window is wider, so cards don't stretch across a
/// desktop window. On a phone it is the child, unchanged. The mouse wheel scrolls the page over the empty side margins
/// too.
class PageColumn extends StatelessWidget {
  const PageColumn({super.key, required this.child, this.maxWidth = pageColumnWidth, this.alignment = Alignment.topCenter});
  final Widget child;

  /// Where the column sits when the window is wider: the rig page's body starts at the header's left edge.
  final Alignment alignment;

  /// Wider than the usual column for a page that uses the width (the rig's graph).
  final double maxWidth;

  /// The first vertical scroll view under [ro] that is on screen (an IndexedStack's other tabs are skipped).
  static RenderViewportBase? _viewport(RenderObject ro) {
    if (ro is RenderViewportBase && ro.axis == Axis.vertical) return ro;
    RenderViewportBase? found;
    ro.visitChildrenForSemantics((c) => found ??= _viewport(c));
    return found;
  }

  void _wheel(BuildContext context, PointerScrollEvent e) {
    final ro = context.findRenderObject();
    final pos = ro == null ? null : _viewport(ro)?.offset;
    if (pos is ScrollPosition) pos.pointerScroll(e.scrollDelta.dy);
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        // Registered after the list's own handler: over the column the list wins, over a margin this one does.
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(e, (e) => _wheel(context, e as PointerScrollEvent));
          }
        },
        child: Align(
          alignment: alignment,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );
}
