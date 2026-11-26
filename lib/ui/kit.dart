import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models.dart';
import '../data/host_store.dart' show isDesktop;
import '../data/needs_you.dart' show needsYouCount;
import 'host_color.dart';
import 'status_shape.dart';
import 'page_column.dart' show pageColumnWidth;
import 'progress_bar.dart' show ContextBar;
import 'usage_strip.dart' show contextColor, contextWeight;
import 'theme.dart';

/// Asks before something that can't be undone, in a bottom sheet like the
/// other sheets (with no [action] it just tells, with a close button). True
/// only when [action] is tapped; [extra] sits under the
/// body (a checkbox) and can rebuild itself through its setter.
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  String? body,
  String? action,
  String cancel = 'Cancel',
  bool destructive = true,
  Widget Function(BuildContext, StateSetter)? extra,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              if (body != null) ...[const SizedBox(height: 8), Text(body)],
              if (extra != null) extra(ctx, setSheet),
              const SizedBox(height: 16),
              if (action != null) ...[
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: destructive ? Tokens.of(ctx).kill : null,
                    foregroundColor: destructive ? Tokens.of(ctx).onAccent : null).merge(sheetAction),
                  child: Text(action),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                style: sheetAction,
                child: Text(cancel),
              ),
            ])),
          ),
        ),
      ),
    ) ??
    false;

/// "A dialog on the Mac, a bottom sheet on a phone": the one way to open a screen of its own over the page. The Mac gets a square
/// Dialog at most [maxWidth] (and [maxHeight]) wide, with [dialogTop] above the content; a phone a drag-handle sheet that scrolls
/// and keeps clear of the notch. [fullHeight] makes the sheet as tall as it can be (a browser); the Mac's dialog keeps [maxHeight].
Future<T?> showDialogOrSheet<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
  double? maxHeight,
  double dialogTop = 0,
  bool fullHeight = false,
}) {
  if (isDesktop) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        shape: const RoundedRectangleBorder(),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight ?? double.infinity),
          child: dialogTop == 0 ? child : Padding(padding: EdgeInsets.only(top: dialogTop), child: child),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => fullHeight ? SizedBox(height: double.infinity, child: child) : child,
  );
}

/// The route name of a page the Mac's sidebar puts in the content panel.
const panelRouteName = 'panel';

/// The shell's menu button, offered to the PageHeader at the root of the content panel while the sidebar is a drawer
/// or folded away.
class ShellMenu extends InheritedWidget {
  const ShellMenu({super.key, required this.open, required super.child});
  final VoidCallback open;
  @override
  bool updateShouldNotify(ShellMenu old) => open != old.open;
}

/// The top of every board: a back button, an overline (the parent), the
/// title, an optional mono subtitle, trailing actions, and an optional row
/// below (tabs, chips, the git bar).
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.overline,
    this.host,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.titleIcon,
    this.large = false,
    this.compact = false,
    this.back,
    this.inColumn = false,
    this.showBack = true,
  });

  final String title;
  final String? overline;

  /// Leads the overline with the host's name, in its color.
  final Host? host;
  final Widget? subtitle;
  final List<Widget> actions;
  final Widget? bottom;

  /// Before the title (the rig page's rig icon).
  final Widget? titleIcon;
  final bool large;

  /// 16 px title (chat and terminal, where the bar carries more).
  final bool compact;

  /// Overrides the back button; null shows it when the route can pop.
  final VoidCallback? back;

  /// False where another header on the screen already has the Back (the rig's header over an agent's).
  final bool showBack;

  /// The header's content (title, tabs) sits in the same [pageColumnWidth] column as the page body under it, on a wide
  /// window; the bar and its line stay full width. For pages whose body is a [PageColumn].
  final bool inColumn;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final t = Theme.of(context).textTheme;
    // A page the Mac's sidebar opened (a panel root) has no back arrow, even over a route that stayed for unsaved edits.
    final panelRoot = isDesktop && ModalRoute.of(context)?.settings.name == panelRouteName;
    final canPop = showBack && (back != null || (!large && !panelRoot && Navigator.of(context).canPop()));
    final menu = canPop ? null : context.dependOnInheritedWidgetOfExactType<ShellMenu>();
    final titleStyle = large ? t.displaySmall : (compact ? t.titleMedium : t.headlineSmall);
    // No status bar above (a desktop window): the header keeps off the window's top edge by 8dp more.
    final topGap = MediaQuery.paddingOf(context).top == 0 ? 8.0 : 0.0;
    return LayoutBuilder(builder: (context, box) {
      // On a window wider than the column the side padding is inside it (20, as the body's), so the title and tabs
      // sit on the body's edges; narrower, the header is as it always was.
      final wide = inColumn && box.maxWidth > pageColumnWidth;
      final side = wide ? 0.0 : (large ? 20.0 : 12.0);
      return _bar(context, k, t, menu, canPop, titleStyle, topGap, side, wide);
    });
  }

  Widget _bar(BuildContext context, Tokens k, TextTheme t, ShellMenu? menu, bool canPop, TextStyle? titleStyle,
      double topGap, double side, bool wide) {
    // A Material, not a filled box, so ink in the header (git line, Retry, host chip) shows above the fill.
    return Material(
      color: k.ground,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.border))),
        padding: EdgeInsets.fromLTRB(side, (large ? 12 : 4) + topGap, side, large ? 12 : (compact ? 8 : 12)),
        child: SafeArea(
          bottom: false,
          child: _headerColumn(
            wide,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            // The three top-level tabs share this row's height, so their titles sit at the same y whether or not
            // an action (the Projects +) is there.
            ConstrainedBox(
              // On the Mac every page's title row is 48dp, so the titles sit at one y whatever buttons share the line.
              constraints: BoxConstraints(minHeight: large || isDesktop ? 48 : 0),
              child: Row(children: [
                if (menu != null)
                  ValueListenableBuilder<int>(
                    valueListenable: needsYouCount,
                    builder: (context, needs, _) => IconButton(
                      tooltip: needs == 0 ? 'Menu' : 'Menu, $needs ${needs == 1 ? 'needs' : 'need'} you',
                      onPressed: menu.open,
                      icon: Badge(
                        isLabelVisible: needs > 0,
                        label: Text('$needs'),
                        backgroundColor: k.accent,
                        textColor: k.onAccent,
                        child: const Icon(Icons.menu, size: 22),
                      ),
                    ),
                  ),
                if (canPop)
                  IconButton(
                    tooltip: 'Back',
                    onPressed: back ?? () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left, size: 26),
                  ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Semantics(
                      header: true,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (host != null)
                              hostOverline(host!, t.labelMedium, rest: overline)
                            else if (overline != null)
                              Text(overline!, style: t.labelMedium, overflow: TextOverflow.ellipsis),
                            if (titleIcon != null)
                              Row(children: [
                                titleIcon!,
                                const SizedBox(width: 8),
                                Expanded(child: Text(title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                              ])
                            else
                              Text(title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                    ),
                    // Outside the header's semantics, so a status line keeps its own label.
                    if (subtitle != null) subtitle!,
                  ]),
                ),
                if (actions.isNotEmpty) const SizedBox(width: 8),
                ...actions,
              ]),
            ),
            if (bottom != null) ...[
              SizedBox(height: large ? 12 : 14),
              Padding(padding: EdgeInsets.symmetric(horizontal: large || wide ? 0 : 8), child: bottom!),
            ],
          ]),
          ),
        ),
      ),
    );
  }

  /// [child] across the header, or on a wide window with [inColumn] centred in a [pageColumnWidth] column.
  Widget _headerColumn(bool wide, Widget child) => wide
      ? Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: pageColumnWidth),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: child)),
        )
      : child;
}

/// The grey segmented control the boards use for tabs (Overview · Graph ·
/// Seats, Chat · Terminal, Summary · YAML).
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.compact = false,
    this.semanticLabel,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Hugs its labels (in a header) instead of filling the width.
  final bool compact;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final k = Tokens.of(context);
    // One size for every label: the largest that lets the widest fit its segment (13 when they all do).
    var size = 13.0;
    if (!compact && box.maxWidth.isFinite) {
      final room = (box.maxWidth - 6) / values.length - 8;
      for (final l in labels) {
        final w = (TextPainter(
          text: TextSpan(text: l, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout())
            .width;
        if (w > room) size = size < 13 * room / w ? size : 13 * room / w;
      }
    }
    final items = [
      for (var i = 0; i < values.length; i++)
        _segment(context, k, labels[i], values[i] == selected, () => onChanged(values[i]), size),
    ];
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
        child: Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [for (final w in items) compact ? w : Expanded(child: w)],
        ),
      ),
    );
  });

  Widget _segment(BuildContext context, Tokens k, String label, bool on, VoidCallback tap, double size) => Semantics(
        selected: on,
        button: true,
        inMutuallyExclusiveGroup: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: kEaseOut,
            height: compact ? 30 : 34,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? k.ground : Colors.transparent,
              borderRadius: BorderRadius.circular(kRadius),
            ),
            // Shrinks rather than wraps when a narrow phone has many segments.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: size, fontWeight: on ? FontWeight.w600 : FontWeight.w400, color: on ? k.ink : k.muted)),
            ),
          ),
        ),
      );
}

/// The one caps label: mono, spaced, muted (a section heading, a field label in a card). Callers upper-case the text.
TextStyle sectionLabelStyle(BuildContext context, {double size = 11}) =>
    mono(context, size: size, color: Tokens.of(context).muted).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.8);

/// "RUNNING · 2": the small uppercase heading above a group. [leading] is a mark before it (the needs-you shape);
/// [height] fixes the row's height and centres it (ProjectScreen's section heads), else it hugs the text.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.leading, this.height});
  final String text;
  final Widget? trailing;
  final Widget? leading;
  final double? height;
  @override
  Widget build(BuildContext context) {
    final row = Row(crossAxisAlignment: height == null && trailing == null ? CrossAxisAlignment.end : CrossAxisAlignment.center, children: [
      if (leading != null) ...[leading!, const SizedBox(width: 8)],
      Expanded(
        child: Semantics(
          header: true,
          child: Text(text.toUpperCase(), style: sectionLabelStyle(context)),
        ),
      ),
      if (trailing != null) trailing!,
    ]);
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: height == null ? row : SizedBox(height: height, child: row));
  }
}

/// A [SectionLabel] over its card: a [BorderedList] of [children], or your own [child] (a Panel). A null [title]
/// leaves the label out. [gap] is the space left below.
class Section extends StatelessWidget {
  const Section(this.title, {super.key, this.children, this.child, this.header, this.trailing, this.gap = 0})
      : assert((children == null) != (child == null), 'one of children or child');
  final String? title;
  final List<Widget>? children;
  final Widget? child;
  final Widget? header;
  final Widget? trailing;
  final double gap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: gap),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) SectionLabel(title!, trailing: trailing),
          child ?? BorderedList(header: header, children: children!),
        ]),
      );
}

/// A group's header line: icon, mono name, then a hairline up to [trailing]. The caller owns the tap, fold and
/// padding around it. [nameShare] is how much of the line the name may take; the hairline gets the rest.
class GroupHeader extends StatelessWidget {
  const GroupHeader({super.key, required this.icon, required this.title, this.trailing, this.nameShare = 0.6});
  final IconData icon;
  final String title;
  final Widget? trailing;
  final double nameShare;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return LayoutBuilder(
      builder: (context, box) => Row(children: [
        Icon(icon, size: 14, color: k.muted),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth * nameShare),
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sectionLabelStyle(context, size: 12)),
        ),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Divider(height: 1, thickness: 1, color: k.border))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// The actions pinned under a screen or sheet: an optional [primary] in the success green, wider than the rest, then
/// the destructive ones as red buttons, side by side. A bar can have only one of them.
/// The destructive red as outlined text on [k]'s ground: the dark theme's lighter error red, pulled in lightness where it
/// still falls short of 4.5:1.
Color outlinedRed(Tokens k) => readableOn(k.kill, k.ground);

class KillBar extends StatelessWidget {
  const KillBar(this.actions, {super.key, this.primary, this.primaryNote, this.outlined = false});

  /// (label, icon, onPressed); a null onPressed disables it.
  final List<(String, IconData, VoidCallback?)> actions;

  /// The one thing to do here, in green, 3 parts to the red buttons' 2 so "Delete rig…" still fits. Disabled when its onPressed is null; [primaryNote] then says why.
  final (String, IconData, VoidCallback?)? primary;
  final String? primaryNote;

  /// The destructive buttons are outlined (red text and hairline), not filled: for a rare action that should not be the
  /// loudest thing on the page. The confirm dialog it opens carries the filled red.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final p = primary;
    Widget button((String, IconData, VoidCallback?) a, {required Color bg, required Color fg}) => FilledButton.icon(
          onPressed: a.$3,
          icon: Icon(a.$2, size: 20),
          label: Text(a.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            padding: const EdgeInsets.symmetric(horizontal: 12)).merge(sheetAction),
        );
    // White on the light theme's green, dark on the dark theme's pale one.
    final onGreen = ThemeData.estimateBrightnessForColor(k.added) == Brightness.dark ? Colors.white : k.ground;
    return DecoratedBox(
      decoration: BoxDecoration(color: k.ground, border: Border(top: BorderSide(color: k.divider))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          // Full width on a phone; on a wide pane each button stops at 360dp, left-aligned with the body.
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 360.0 * (actions.length + (p == null ? 0 : 1))),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (p != null && p.$3 == null && primaryNote != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(primaryNote!, style: TextStyle(fontSize: 12, color: k.muted)),
                  ),
                Row(children: [
                  if (p != null)
                    Expanded(flex: 3, child: button(p, bg: k.added, fg: onGreen)),
                  for (final (i, a) in actions.indexed) ...[
                    if (i > 0 || p != null) const SizedBox(width: 8),
                    Expanded(
                        flex: p == null ? 1 : 2,
                        child: outlined
                            ? OutlinedButton.icon(
                                onPressed: a.$3,
                                icon: Icon(a.$2, size: 20),
                                label: Text(a.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
                                // The dark theme's lighter error red (the filled red is too dim as text on its ground).
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: outlinedRed(k),
                                  side: BorderSide(color: outlinedRed(k)),
                                  padding: const EdgeInsets.symmetric(horizontal: 12)).merge(sheetAction),
                              )
                            : button(a, bg: k.kill, fg: k.onAccent)),
                  ],
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A ⋯ menu as a bottom sheet: (icon, title, subtitle, action) rows, then the destructive [danger] actions as red
/// buttons pinned at the bottom. A null action disables its row. The pick runs after the sheet has closed, and only
/// if [context] is still mounted.
Future<void> showActionSheet(BuildContext context, String? title, List<(IconData, String, String?, VoidCallback?)> items,
    {List<(String, IconData, VoidCallback)> danger = const []}) async {
  final pick = await showModalBottomSheet<VoidCallback>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (title != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
        ),
      for (final (icon, label, subtitle, action) in items)
        OptionRow(
          leading: Icon(icon, size: 24),
          title: Text(label),
          subtitle: subtitle == null ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: action == null ? null : () => Navigator.pop(ctx, action),
        ),
      const SizedBox(height: 8),
      if (danger.isEmpty)
        const SafeArea(top: false, child: SizedBox.shrink())
      else
        KillBar([for (final (label, icon, action) in danger) (label, icon, () => Navigator.pop(ctx, action))]),
    ])),
  );
  // The screen may have gone while the sheet was open: then the row has nothing to act on.
  if (!context.mounted) return;
  pick?.call();
}

/// Rows inside one hairline card, separated by lighter rules.
class BorderedList extends StatelessWidget {
  const BorderedList({super.key, required this.children, this.header, this.borderColor, this.stripHeader = true});
  final List<Widget> children;

  /// A colored outline is a state (needs you, failed); it gets its neon halo in the dark theme.
  final Color? borderColor;

  /// A grey strip on top (pod label, "3 files changed").
  final Widget? header;

  /// False when [header] is a row of its own (it draws its own background and rule): it goes in as it is.
  final bool stripHeader;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    // The border lives on the Material so it paints over the clipped rows;
    // on a Container the rows' square corners would cover it.
    return Material(
      color: k.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: borderColor ?? k.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (header != null)
          stripHeader
              ? Container(
                  color: k.headerFill, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: header)
              : header!,
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 || (header != null && stripHeader)) Divider(color: k.divider),
          children[i],
        ],
      ]),
    );
  }
}

/// A plain hairline card.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap, this.borderColor});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Material(
      color: k.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: BorderSide(color: borderColor ?? k.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Rows are 48dp for a finger, 28 with a mouse. A desktop starts dense, before any pointer event.
bool navMouse() => isDesktop || WidgetsBinding.instance.mouseTracker.mouseIsConnected;
double navRowHeight() => navMouse() ? 32 : 48;

/// A row's name line is 18 tall; with a second line (a context bar, a worktree, an address) a mouse row's padding is 4, else 7, and
/// the first line's centre is y 13 instead of 16 (a finger's: 17 instead of 24).
const navNameLineH = 18.0, navSecondLineH = 14.0;

/// The padding above a row's name line: one line, a mouse's 7 (a finger's row is centred); two or more, 4 (a finger's 8).
double navRowTop({required bool twoLines}) => navMouse() ? (twoLines ? 4 : 7) : (twoLines ? 8 : (48 - navNameLineH) / 2);

double navSideInset() => navMouse() ? 10 : 16;
const navSlotW = 16.0, navIconGap = 9.0;

/// The sidebar's one trailing column, ending at the row's right edge: chevrons, the hover ⋯, retry, collapse and the footer ⋯ sit
/// centred in it (24 with a mouse, a finger's 44 otherwise). Counts and ages end at its left edge, so one x for all of them.
double navTrailW() => navMouse() ? 24 : 44;

/// A row's content sits this far inside its selected fill, so the icon doesn't touch the fill's edge.
const navFillInset = 6.0;

/// A flat row of the sidebar and the drawer (Rigs, Inbox, Hosts and settings, a host's header, Add project folder):
/// one height, inset, icon slot and label x, one ripple and selected fill. [dashed] is the only look that differs
/// (Add project folder); [dimmed] mutes it (the host is offline). A null [onTap] is inert. Tree rows are the shell's own.
class NavRow extends StatelessWidget {
  const NavRow({
    super.key,
    this.leading,
    this.leadingWidth = navSlotW,
    required this.label,
    this.labelStyle,
    this.body,
    this.meta,
    this.count = 0,
    this.selected = false,
    this.dashed = false,
    this.dimmed = false,
    this.onTap,
    this.onMore,
    this.endLabel,
    this.trailing,
  });
  final Widget? leading;

  /// The icon slot's width: a 10dp host swatch takes 10, not the icons' 16.
  final double leadingWidth;
  final String label;
  final TextStyle? labelStyle;

  /// Drawn in place of the label's text (a count beside the name); [label] still says it to a screen reader.
  final Widget? body;
  final String? meta;

  /// Agents waiting on you, as a count at the right.
  final int count;
  /// Text at the right that ends where the counts do, before the trailing column (a host's folded count, 'host offline').
  final Widget? endLabel;
  final bool selected, dashed, dimmed;
  final VoidCallback? onTap;

  /// The row's action list: a ⋯ button, a long press and a right click all open it.
  final VoidCallback? onMore;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final h = navRowHeight();
    final said = count > 0 ? '$label, $count need you' : null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: navSideInset()),
      child: Semantics(
        selected: selected,
        button: onTap != null || dashed,
        enabled: onTap != null,
        label: said,
        child: CustomPaint(
          foregroundPainter: dashed ? DashedBorder(k.border, radius: kRadius) : null,
          child: Material(
            color: selected ? k.ground : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadius),
              side: BorderSide(color: selected ? k.border : Colors.transparent),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadius),
              onTap: onTap,
              onLongPress: onMore,
              onSecondaryTap: onMore,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: h),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(navFillInset, navRowTop(twoLines: meta != null && meta!.isNotEmpty), navFillInset, navMouse() ? (meta != null && meta!.isNotEmpty ? 4 : 7) : 0),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // Everything on the first line is centred on the name line.
                    SizedBox(
                      height: navNameLineH,
                      child: Row(children: [
                        SizedBox(width: leadingWidth, child: Center(child: leading)),
                        const SizedBox(width: navIconGap),
                        Expanded(
                          child: body ??
                              Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: labelStyle ??
                                      TextStyle(
                                          fontSize: 13,
                                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                          color: dimmed ? k.muted : k.ink)),
                        ),
                        if (count > 0) ExcludeSemantics(child: Text('$count', style: mono(context, color: k.accent, weight: FontWeight.w600))),
                        if (endLabel != null) Padding(padding: const EdgeInsets.only(left: 6), child: endLabel),
                        // The trailing column is there on every row (empty when nothing is in it), so the counts end at one x.
                        SizedBox(
                          width: navTrailW(),
                          child: OverflowBox(
                            minHeight: 0,
                            maxHeight: h - 4,
                            child: Center(
                              child: onMore != null
                                  ? IconButton(
                                      tooltip: 'Actions for $label',
                                      padding: EdgeInsets.zero,
                                      constraints: BoxConstraints.tightFor(width: navTrailW(), height: h - 4),
                                      style: IconButton.styleFrom(minimumSize: Size(navTrailW(), h - 4), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                      onPressed: onMore,
                                      icon: Icon(Icons.more_horiz, size: 16, color: k.muted),
                                    )
                                  : trailing,
                            ),
                          ),
                        ),
                      ]),
                    ),
                    // The second line (an offline host's address): the label's column, mono 11, muted, one line, ending where the counts do.
                    if (meta != null && meta!.isNotEmpty)
                      SizedBox(
                        height: navSecondLineH,
                        child: Padding(
                          padding: EdgeInsets.only(left: leadingWidth + navIconGap, right: navTrailW()),
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(meta!, style: mono(context, size: 11, color: k.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill colors. good = green (active, working, running), done = green
/// outline (finished), bad = red (blocked, failed), hot = orange (needs you).
enum Tone { ink, hot, light, outline, dashed, live, good, done, bad, shell }

/// Small rounded label: queue states, seat pills, "needs you", "live".
class Pill extends StatelessWidget {
  const Pill(this.text,
      {super.key,
      this.tone = Tone.light,
      this.height = 22,
      this.fontSize = 11,
      this.width,
      this.bold = true,
      this.semanticsLabel});
  final String text;

  /// What a screen reader says instead of [text] (a bare count says "3 need you").
  final String? semanticsLabel;
  final Tone tone;
  final double height;
  final double fontSize;
  final double? width;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final (Color? bg, Color fg, Color? line) = switch (tone) {
      Tone.ink => (k.ink, k.onInk, null),
      Tone.hot => (k.accent, k.onAccent, null),
      Tone.light => (k.fill, k.ink, null),
      Tone.outline => (null, k.ink, k.ink),
      Tone.dashed => (null, k.muted, null),
      Tone.live => (k.removed, k.onAccent, null),
      Tone.good => (k.added, k.onAccent, null),
      Tone.done => (null, k.added, k.added),
      Tone.bad => (k.removed, k.onAccent, null),
      Tone.shell => (null, k.shell, k.shell),
    };
    final label = Text(text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: fontSize, height: 1.2, fontWeight: bold ? FontWeight.w600 : FontWeight.w400, color: fg));
    final box = Container(
      width: width,
      constraints: BoxConstraints(minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: line == null ? null : Border.all(color: line),
        borderRadius: BorderRadius.circular(kRadius),
      ),
      // The factors center the text while the pill still hugs it; Container's
      // own alignment would make it fill its parent.
      child: Align(widthFactor: 1, heightFactor: 1, child: label),
    );
    final pill = tone != Tone.dashed ? box : CustomPaint(painter: DashedBorder(k.faint, radius: height / 2), child: box);
    return semanticsLabel == null ? pill : Semantics(label: semanticsLabel, excludeSemantics: true, child: pill);
  }
}

/// The text color a pill of [t] draws in, for status shown as plain text.
Color toneColor(Tokens k, Tone t) => switch (t) {
      Tone.good || Tone.done => k.added,
      Tone.bad || Tone.live => k.removed,
      Tone.hot => k.accent,
      Tone.shell => k.shell,
      Tone.ink || Tone.outline => k.ink,
      Tone.light || Tone.dashed => k.muted,
    };

/// One color per status word, everywhere a status is shown as a pill:
/// queue items, slices, rigs, pull requests, inbox kinds.
Tone statusTone(String status) => switch (status.toLowerCase().replaceAll('_', '-')) {
      'active' || 'in-progress' || 'in progress' || 'working' || 'running' || 'claimed' || 'open' => Tone.good,
      'done' || 'completed' || 'merged' || 'passing' || 'approved' || 'ready' => Tone.done,
      'blocked' || 'failed' || 'denied' || 'error' || 'degraded' || 'changes-requested' => Tone.bad,
      'needs you' || 'needs-you' || 'attention-required' || 'permission' || 'question' || 'approval' => Tone.hot,
      'pending' || 'partial' || 'handed-off' || 'handed off' => Tone.outline,
      _ => Tone.light,
    };

String labelFor(SeatState s) => Status.of(s).label;

/// The one wording of a seat's state: 'at usage limit' when it is (in any state a seat can be at its limit in, the screen-reader
/// label included), else [labelFor] its state, saying "on subagents" when only subagents keep it waiting.
String seatLabel(Seat s) => usageLimitLine(s) != null
    ? 'at usage limit'
    : s.state == SeatState.shell && s.jobs.isEmpty
        ? 'on subagents'
        : labelFor(s.state);

/// Pill-shaped small button: Start (ink), Restore and Open rig (ink outline).
class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, required this.onPressed, this.filled = false, this.height = 32});
  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final double height;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius));
    const pad = EdgeInsets.symmetric(horizontal: 14);
    final text = Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600));
    return filled
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
                minimumSize: Size(44, height), padding: pad, shape: shape, tapTargetSize: MaterialTapTargetSize.padded),
            child: text,
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
                minimumSize: Size(44, height), padding: pad, shape: shape, side: BorderSide(color: k.ink)),
            child: text,
          );
  }
}

/// A row of the boards' lists: min 60 px, leading, title + meta, trailing. It is also Home's row pattern:
/// with [fold] a left chevron (folds and unfolds, nothing else) sits beside a body that opens the detail
/// screen via [onTap] and ends in a › ([arrow]). The body's ripple fills the row up to the chevron; both are
/// real buttons for keyboard and screen readers.
///
/// The chevron sits in a slot [tileFoldMax] wide, so titles line up across rows; its tap square is as tall as the
/// row, clamped to [tileFoldMin]..[tileFoldMax], and centred in the slot. Without [fold] there is no slot at all.
class RowTile extends StatelessWidget {
  const RowTile({
    super.key,
    this.leading,
    this.title,
    this.child,
    this.meta,
    this.metaMono = false,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.longPressHint,
    this.minHeight = 60,
    this.extra,
    this.chips,
    this.metaColor,
    this.titleTrailing,
    this.fold,
    this.openLabel,
    this.arrow = false,
    this.reserveFold = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  }) : assert(title != null || child != null);
  final Widget? leading;
  final String? title;

  /// Replaces the title, meta, extra and chips with your own content (Home's rows).
  final Widget? child;

  /// Sits right after the title (the runtime glyph on seat rows).
  final Widget? titleTrailing;
  final String? meta;
  final bool metaMono;

  /// Sits before the arrow, 8dp clear of the content; its buttons take their own taps.
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// What a screen reader says the long press does ('more actions'): without it the action has no name.
  final String? longPressHint;
  final double minHeight;

  final Color? metaColor;
  final EdgeInsets padding;

  /// A third line (spec rows show path and summary).
  final String? extra;

  /// Small status chips under the text (worktree rows).
  final List<Widget>? chips;

  /// The fold chevron: [name] is what it folds, for the tooltip and screen readers. Null: no chevron slot.
  final ({String name, bool open, VoidCallback onTap})? fold;

  /// What a screen reader says for the body; null reads the content as it is.
  final String? openLabel;

  /// A › at the end (not shown when [onTap] is null): the row opens a screen.
  final bool arrow;

  /// With no [fold]: still leave the chevron's slot empty, so this row's title lines up with its foldable siblings.
  final bool reserveFold;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final fold = this.fold;
    final body = Semantics(
      button: onTap != null,
      label: openLabel,
      excludeSemantics: openLabel != null,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressHint: longPressHint,
      // One node for screen readers (button, label, tap, long press): the InkWell adds none of its own.
      child: InkWell(
        excludeFromSemantics: true,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            // Beside a chevron the chevron is the left margin; a reserved slot is padding inside the ink.
            padding: (fold != null
                    ? padding.copyWith(left: 0)
                    : reserveFold
                        ? padding.copyWith(left: tileFoldMax)
                        : padding)
                .copyWith(right: arrow && onTap != null ? tileArrowInset : null),
            child: Row(children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: child ??
                    Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      if (titleTrailing == null)
                        Text(title!, style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500, height: 1.3))
                      else
                        Row(children: [
                          Flexible(
                            child: Text(title!,
                                style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500, height: 1.3),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 6),
                          titleTrailing!,
                        ]),
                      if (meta != null) ...[
                        const SizedBox(height: 2),
                        // Paths and addresses stay on one line.
                        Text(meta!,
                            style: metaMono ? mono(context) : t.bodySmall?.copyWith(color: metaColor),
                            maxLines: metaMono ? 1 : null,
                            overflow: metaMono ? TextOverflow.ellipsis : null),
                      ],
                      if (extra != null) ...[
                        const SizedBox(height: 2),
                        Text(extra!, style: t.bodySmall),
                      ],
                      if (chips case final c? when c.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: c),
                      ],
                    ]),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              if (arrow && onTap != null) const Chevron(),
            ]),
          ),
        ),
      ),
    );
    if (fold == null) {
      return body;
    }
    return _TileLayout(minHeight: minHeight, children: [
      Semantics(
        button: true,
        expanded: fold.open,
        label: '${fold.open ? 'Fold' : 'Unfold'} ${fold.name}',
        excludeSemantics: true,
        onTap: fold.onTap,
        child: Tooltip(
          message: '${fold.open ? 'Fold' : 'Unfold'} ${fold.name}',
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadius),
            onTap: fold.onTap,
            child: Center(child: FoldChevron(fold.open)),
          ),
        ),
      ),
      body,
    ]);
  }
}

/// One option in a sheet's or menu's list: the [RowTile] look at 48dp, in place of Material's ListTile (56 / 72).
/// A null [onTap] dims it.
class OptionRow extends StatelessWidget {
  const OptionRow({super.key, this.leading, required this.title, this.subtitle, this.trailing, this.onTap});
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final row = RowTile(
      minHeight: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: leading,
      trailing: trailing,
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        DefaultTextStyle.merge(style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500), child: title),
        if (subtitle != null)
          DefaultTextStyle.merge(style: t.bodySmall?.copyWith(color: Tokens.of(context).muted), child: subtitle!),
      ]),
    );
    return onTap == null ? Opacity(opacity: .38, child: row) : row;
  }
}

/// Tells its builder whether the mouse is over it.
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;
  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered));
}

/// An agent's row, the one design for a card list (the rig page's Agents tab): its icon with the state dot, its name (with
/// NEEDS YOU in the accent when it waits), what it is doing under it, and at the right its age over the context bar and
/// percent, then the ⋯. [kind] is the icon's family (an agent's robot, a subagent's fork, a shell's terminal); a shell has
/// no context. A null [onTap] leaves it inert (a seat still starting); [dim] fades it.
class AgentRow extends StatelessWidget {
  const AgentRow({
    super.key,
    required this.name,
    required this.status,
    this.kind = StatusKind.agent,
    this.runtime,
    this.needsYou = false,
    this.extra,
    this.task,
    this.age,
    this.context,
    this.taskColor,
    this.dim = false,
    this.indent = 0,
    this.moreSlot = false,
    this.expanded,
    this.action,
    this.ageOnTitle = false,
    this.tint,
    this.onTap,
    this.onMore,
    this.moreTooltip,
    this.openLabel,
  });
  final String name;
  final Status status;
  final StatusKind kind;

  /// The agent's runtime: its logo is the icon, in the state's colour.
  final String? runtime;
  final bool needsYou;

  /// After the name, small mono: its worktree (when not main) or runtime (when not Claude).
  final String? extra;

  /// What it is doing or asking.
  final String? task;
  final String? age;

  /// Context used, in percent.
  final double? context;

  /// The task line's colour when it is not the muted default (a seat at its usage limit: muted red).
  final Color? taskColor;
  final bool dim;

  /// How far in: a subagent or shell nests one step under its agent.
  final double indent;

  /// With a mouse, keep the ⋯'s room although there is no ⋯ (a nested row), so every row's age ends at one right edge.
  final bool moreSlot;

  /// A row that opens in place (the Inbox card): a small chevron at the right end, up when open. Null: none.
  final bool? expanded;

  /// A small button before the age and context (a failed seat's Retry).
  final Widget? action;

  /// The age at the end of the title line, not centred in the row's right column (the Inbox card's header).
  final bool ageOnTitle;

  /// The row's fill (its state's tint); the surface when null.
  final Color? tint;
  final VoidCallback? onTap;
  final VoidCallback? onMore;
  final String? moreTooltip;

  /// What a screen reader says for the row.
  final String? openLabel;

  @override
  Widget build(BuildContext context) => HoverBuilder(builder: _row);

  Widget _row(BuildContext context, bool hovered) {
    final k = Tokens.of(context);
    final ctx = this.context;
    final ground = tint ?? k.surface;
    // The age over the context bar and percent, at the right.
    final Widget? meter = (age == null || ageOnTitle) && ctx == null
        ? null
        : Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                        if (age != null && !ageOnTitle) Text(age!, style: mono(context, size: 11, color: k.muted)),
                        if (ctx != null) ...[
                          const SizedBox(height: 4),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            SizedBox(width: 56, child: ContextBar(ctx, height: 3, base: k.muted, label: false)),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 30,
                              child: Text('${ctx.round()}%',
                                  textAlign: TextAlign.right,
                                  style: mono(context, size: 11, color: contextColor(ctx, k)).copyWith(fontWeight: contextWeight(ctx))),
                            ),
                          ]),
                        ],
                      ]);
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: Material(
        color: ground,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: k.divider))),
          child: Row(children: [
            Expanded(
              child: RowTile(
                minHeight: 56,
                padding: EdgeInsets.fromLTRB(14 + indent, 8, 4, 8),
                onTap: onTap,
                // A finger long-presses the row (a mouse right-clicks it) for its list; the ⋯ shows on hover.
                onLongPress: onMore,
                longPressHint: onMore == null ? null : (moreTooltip ?? 'more actions'),
                openLabel: openLabel,
                leading: switch (kind) {
                  StatusKind.agent => StatusIcon.agent(status, ground: ground, runtime: runtime),
                  StatusKind.subagent => StatusIcon.subagent(status, ground: ground),
                  StatusKind.shell => StatusIcon.shell(status, ground: ground),
                },
                trailing: meter == null && expanded == null && action == null
                    ? null
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        if (action != null) action!,
                        if (meter != null) meter,
                        if (expanded != null) Padding(
                          padding: const EdgeInsets.only(left: 8, right: 10),
                          child: Icon(expanded! ? Icons.expand_less : Icons.expand_more, size: 18, color: k.muted),
                        ),
                      ]),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (ageOnTitle && age != null)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child:                   Text.rich(
                    TextSpan(children: [
                      TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (extra != null) TextSpan(text: '  $extra', style: mono(context, size: 10, color: k.muted)),
                      if (needsYou)
                        TextSpan(
                            text: '  NEEDS YOU',
                            style: mono(context, size: 10, color: k.accent).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.8)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: k.ink),
                  )
                      ),
                      const SizedBox(width: 8),
                      Text(age!, style: mono(context, size: 11, color: k.muted)),
                    ])
                  else
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (extra != null) TextSpan(text: '  $extra', style: mono(context, size: 10, color: k.muted)),
                      if (needsYou)
                        TextSpan(
                            text: '  NEEDS YOU',
                            style: mono(context, size: 10, color: k.accent).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.8)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: k.ink),
                  ),
                  if (task != null)
                    Text(task!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: taskColor ?? (needsYou ? k.ink : k.muted))),
                ]),
              ),
            ),
            if (onMore == null && moreSlot && navMouse()) const SizedBox(width: 48),
            if (onMore != null && navMouse())
              Opacity(
                opacity: hovered ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !hovered,
                  child: IconButton(tooltip: moreTooltip ?? 'Details', onPressed: onMore, icon: const Icon(Icons.more_horiz, size: 20)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The logo of what an agent runs on, in that family's color.
class RuntimeGlyph extends StatelessWidget {
  const RuntimeGlyph(this.runtime, {super.key, this.size = 16, this.color});
  final String? runtime;
  final double size;

  /// Overrides the family color (grey for an idle agent).
  final Color? color;

  /// The family's color, or null for a runtime without one.
  static Color? brand(String? runtime) => switch (runtime) {
        'claude-code' => const Color(0xFFD97757),
        'codex' => const Color(0xFF10A37F),
        _ => null,
      };

  /// How the glyph reads out: "Claude Code", "Codex", or the raw runtime.
  static String label(String? runtime) => switch (runtime) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        null => 'unknown runtime',
        final r => r,
      };

  @override
  Widget build(BuildContext context) => switch (runtime) {
        'claude-code' => ImageIcon(const AssetImage('assets/icons/claude.png'),
            size: size, color: color ?? brand(runtime), semanticLabel: label(runtime)),
        'codex' => ImageIcon(const AssetImage('assets/icons/openai.png'),
            size: size, color: color ?? brand(runtime), semanticLabel: label(runtime)),
        _ => Icon(Icons.smart_toy_outlined,
            size: size, color: color ?? Tokens.of(context).muted, semanticLabel: label(runtime)),
      };
}

/// The grey chevron at the end of tappable rows.
class Chevron extends StatelessWidget {
  const Chevron({super.key});
  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: Icon(Icons.chevron_right, size: tileArrowWidth, color: Tokens.of(context).faint));
}

/// The › on a row is this wide and ends this far from the row's right edge, whatever the row's own padding: every
/// › on a screen forms one straight column.
const double tileArrowWidth = 18;
const double tileArrowInset = 8;

/// The fold chevron's smallest and largest side. Change here to resize every [OpenTile] chevron.
const double tileFoldMin = 44;
const double tileFoldMax = 56;

/// The chevron that turns a quarter when [open].
class FoldChevron extends StatelessWidget {
  const FoldChevron(this.open, {super.key, this.size = 18});
  final bool open;
  final double size;
  @override
  Widget build(BuildContext context) => AnimatedRotation(
        turns: open ? 0.25 : 0,
        duration: const Duration(milliseconds: 180),
        curve: kEaseOut,
        child: Icon(Icons.chevron_right, size: size, color: Tokens.of(context).muted),
      );
}

class _TileData extends ContainerBoxParentData<RenderBox> {}

class _TileLayout extends MultiChildRenderObjectWidget {
  const _TileLayout({required this.minHeight, required super.children});
  final double minHeight;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTile(minHeight);
  @override
  void updateRenderObject(BuildContext context, _RenderTile r) => r.minHeight = minHeight;
}

/// Lays out [chevron?, body]: the body first, to learn the row's height, which sets the chevron's side.
class _RenderTile extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _TileData>, RenderBoxContainerDefaultsMixin<RenderBox, _TileData> {
  _RenderTile(this._minHeight);
  double _minHeight;
  set minHeight(double v) {
    if (v == _minHeight) return;
    _minHeight = v;
    markNeedsLayout();
  }

  RenderBox get _body => lastChild!;
  RenderBox get _fold => firstChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TileData) child.parentData = _TileData();
  }

  /// The chevron's square side for a row [rowH] tall.
  double _side(double rowH) => rowH.clamp(tileFoldMin, tileFoldMax).toDouble();

  BoxConstraints _bodyConstraints(double w) => BoxConstraints(
        minWidth: w - tileFoldMax,
        maxWidth: w - tileFoldMax,
        minHeight: max(_minHeight, tileFoldMin),
      );

  // The body at the width left of the slot, at least as tall as the minimum row. A body holding a LayoutBuilder
  // can't answer these (Flutter asserts); no tile is placed under an Intrinsic* widget.
  @override
  double computeMinIntrinsicWidth(double h) => _body.getMinIntrinsicWidth(h) + tileFoldMax;
  @override
  double computeMaxIntrinsicWidth(double h) => _body.getMaxIntrinsicWidth(h) + tileFoldMax;
  @override
  double computeMinIntrinsicHeight(double w) =>
      max(_body.getMinIntrinsicHeight(w - tileFoldMax), max(_minHeight, tileFoldMin));
  @override
  double computeMaxIntrinsicHeight(double w) =>
      max(_body.getMaxIntrinsicHeight(w - tileFoldMax), max(_minHeight, tileFoldMin));

  @override
  Size computeDryLayout(BoxConstraints c) => Size(c.maxWidth, _body.getDryLayout(_bodyConstraints(c.maxWidth)).height);

  @override
  void performLayout() {
    final w = constraints.maxWidth;
    // Not tight in height: a tight body would be its own relayout boundary and never tell the tile it grew.
    _body.layout(_bodyConstraints(w), parentUsesSize: true);
    final rowH = _body.size.height;
    (_body.parentData! as _TileData).offset = const Offset(tileFoldMax, 0);
    // The slot is always tileFoldMax wide, so titles line up across rows; the tap square inside it follows the height.
    final side = _side(rowH);
    _fold.layout(BoxConstraints.tightFor(width: side, height: side));
    (_fold.parentData! as _TileData).offset = Offset((tileFoldMax - side) / 2, (rowH - side) / 2);
    size = constraints.constrain(Size(w, rowH));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// A dashed rounded outline (stopped seats, pod bands).
class DashedBorder extends CustomPainter {
  DashedBorder(this.color, {required this.radius, this.width = 1.5, this.dash = 5, this.gap = 4});
  final Color color;
  final double radius;
  final double width;
  final double dash;
  final double gap;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash + gap) {
        canvas.drawPath(m.extractPath(d, min(d + dash, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorder old) => old.color != color || old.radius != radius;
}

/// The runtime square (CC, CX, SH).
class RuntimeSquare extends StatelessWidget {
  const RuntimeSquare(this.label, {super.key, this.size = 36});
  final String label;
  final double size;
  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
      child: Text(label, style: mono(context, size: 11, color: k.ink, weight: FontWeight.w500)),
    );
  }
}

/// The rig's agents as tabs under a seat's chat or terminal header, each
/// with its state's circle (see [StatusShape]).
class SeatTabs extends StatelessWidget {
  const SeatTabs({super.key, required this.seats, required this.selected, required this.onTap});
  final List<Seat> seats;

  /// The logical id of the seat on screen.
  final String selected;
  final ValueChanged<Seat> onTap;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final s in seats)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: s.logicalId == selected ? null : () => onTap(s),
            child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 7, 6, 7),
            child: Builder(builder: (context) {
              final on = s.logicalId == selected;
              final state = seatLabel(s);
              return Semantics(
                selected: on,
                // The current tab takes no tap, so it is not offered as a button.
                button: !on,
                label: '${s.logicalId}, $state',
                onTap: on ? null : () => onTap(s),
                excludeSemantics: true,
                child: Material(
                  color: on ? k.ink : k.ground,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kRadius), side: on ? BorderSide.none : BorderSide(color: k.border)),
                  child: InkWell(
                    customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
                    onTap: on ? null : () => onTap(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        // On the selected (ink) tab the circle sits on a ground disc, so its outline still reads.
                        Container(
                          width: 16,
                          height: 16,
                          alignment: Alignment.center,
                          decoration: on ? BoxDecoration(color: k.ground, shape: BoxShape.circle) : null,
                          child: StatusShape(Status.of(s.state), size: 12, semantics: false),
                        ),
                        const SizedBox(width: 4),
                        Text(s.logicalId,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                                color: on ? k.onInk : k.ink)),
                      ]),
                    ),
                  ),
                ),
              );
            }),
          )),
      ]),
    );
  }
}

/// A text field in a bottom sheet; the entered text, or null when cancelled.
Future<String?> inputSheet(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String? helper,
  String action = 'Save',
  String cancel = 'Cancel',
  int lines = 1,
  bool code = false,
  TextCapitalization capitalization = TextCapitalization.none,
}) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _InputSheet(title, initial, hint, helper, action, cancel, lines, code, capitalization),
    );

class _InputSheet extends StatefulWidget {
  const _InputSheet(
      this.title, this.initial, this.hint, this.helper, this.action, this.cancel, this.lines, this.code, this.caps);
  final String title, initial, action, cancel;
  final String? hint, helper;
  final int lines;
  final bool code;
  final TextCapitalization caps;
  @override
  State<_InputSheet> createState() => _InputSheetState();
}

class _InputSheetState extends State<_InputSheet> {
  late final _ctrl = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          // Lifts the sheet over the keyboard.
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              minLines: widget.lines,
              maxLines: widget.lines < 2 ? 1 : widget.lines + 4,
              autocorrect: !widget.code,
              enableSuggestions: !widget.code,
              textCapitalization: widget.caps,
              style: widget.code ? const TextStyle(fontFamily: fontMono, fontSize: 13) : null,
              decoration: InputDecoration(hintText: widget.hint, helperText: widget.helper, helperMaxLines: 2),
              onSubmitted: widget.lines > 1 ? null : (v) => Navigator.pop(context, v),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, _ctrl.text),
              style: sheetAction,
              child: Text(widget.action),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: sheetAction,
              child: Text(widget.cancel),
            ),
          ])),
        ),
      );
}
