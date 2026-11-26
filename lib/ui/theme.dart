import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// The app's one motion curve: a strong ease-out. It starts fast, so a change answers at once, and settles gently.
const kEaseOut = Cubic(0.23, 1, 0.32, 1);

/// Desktop screens: the new one fades in over a short 8px slide, 200ms in, 150ms back. The phone keeps the platform's
/// own transitions (iOS swipe-back). With reduced motion it only fades.
class DesktopPageTransitions extends PageTransitionsBuilder {
  const DesktopPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final a = CurvedAnimation(parent: animation, curve: kEaseOut, reverseCurve: kEaseOut.flipped);
    final fade = FadeTransition(opacity: a, child: child);
    if (MediaQuery.disableAnimationsOf(context)) return fade;
    return LayoutBuilder(
      builder: (context, box) => SlideTransition(
        position: Tween(begin: Offset(box.maxWidth > 0 ? 8 / box.maxWidth : 0, 0), end: Offset.zero).animate(a),
        child: fade,
      ),
    );
  }
}

/// The colors: flat neutral surfaces with hairlines, like Zed's One Dark and One Light. Only state is colored, in
/// muted hues (orange needs you, green working, blue shell, red failed).
@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.ink,
    required this.ground,
    required this.muted,
    required this.faint,
    required this.border,
    required this.divider,
    required this.fill,
    required this.headerFill,
    required this.accent,
    required this.onAccent,
    required this.kill,
    required this.onInk,
    required this.termBg,
    required this.termFg,
    required this.termDim,
    required this.added,
    required this.removed,
    required this.amber,
    required this.shell,
    required this.terminal,
    required this.surface,
    required this.isDark,
  });

  /// Text and primary buttons (#1A1A1A).
  final Color ink;

  /// Page background (#FFFFFF).
  final Color ground;

  /// Secondary text (#616161).
  final Color muted;

  /// Chevrons, dashed outlines (#9E9E9E).
  final Color faint;

  /// Card and input outlines (#D9D9D9).
  final Color border;

  /// Row separators inside cards (#EBEBEB).
  final Color divider;

  /// Search field, segmented control, chips, code boxes (#F2F2F2).
  final Color fill;

  /// Card header strips (#F7F7F7).
  final Color headerFill;

  /// Needs you (#B54700).
  final Color accent;
  final Color onAccent;

  /// The destructive fill (Kill session, Stop rig); [onAccent] reads on it in both themes.
  final Color kill;
  final Color onInk;

  /// Terminal and code panes (#161616 / #E6E6E6).
  final Color termBg;
  final Color termFg;
  final Color termDim;

  /// Git line counts and diffs.
  final Color added;
  final Color removed;

  /// The middle of the usage pace gradient (green → amber → red): on pace.
  final Color amber;

  /// Waiting on a shell or monitor: running, but spending no tokens. The same blue as a shell's icon ([terminal]): the
  /// agent's hollow ring and the shell nested under it read together.
  final Color shell;

  /// A shell's icon (blue: a kind, never a state; a subagent's icon takes its state colour). 4.3:1 or more on every
  /// sidebar and page ground.
  final Color terminal;

  /// Cards, sheets and dialogs: a step above [ground].
  final Color surface;

  /// The dark theme (Zed's One Dark); light is One Light.
  final bool isDark;

  static const light = Tokens(
    ink: Color(0xFF383A42),
    ground: Color(0xFFFAFAFA),
    muted: Color(0xFF5C6370),
    faint: Color(0xFF9E9E9E),
    border: Color(0xFFDCDCDD),
    divider: Color(0xFFE8E8E9),
    fill: Color(0xFFEAEAEB),
    headerFill: Color(0xFFEBEBEC),
    accent: Color(0xFFB4581E),
    onAccent: Color(0xFFFFFFFF),
    kill: Color(0xFFC62828),
    onInk: Color(0xFFFFFFFF),
    termBg: Color(0xFF161616),
    termFg: Color(0xFFE6E6E6),
    termDim: Color(0xFFA8A8A8),
    added: Color(0xFF34804A),
    removed: Color(0xFFC2475A),
    amber: Color(0xFF946A00),
    shell: Color(0xFF2F6DB5),
    terminal: Color(0xFF2F6DB5),
    surface: Color(0xFFFAFAFA),
    isDark: false,
  );

  static const dark = Tokens(
    ink: Color(0xFFDCE0E5),
    ground: Color(0xFF282C33),
    muted: Color(0xFFA9AFBC),
    faint: Color(0xFF6B707B),
    border: Color(0xFF3B414D),
    divider: Color(0xFF30353E),
    fill: Color(0xFF2F343E),
    headerFill: Color(0xFF2F343E),
    accent: Color(0xFFD9915B),
    onAccent: Color(0xFF282C33),
    kill: Color(0xFFD67A7F),
    onInk: Color(0xFF282C33),
    termBg: Color(0xFF21252B),
    termFg: Color(0xFFE6E6E6),
    termDim: Color(0xFFA8A8A8),
    added: Color(0xFFA1C181),
    removed: Color(0xFFD07277),
    amber: Color(0xFFE5C07B),
    shell: Color(0xFF7FAEF0),
    terminal: Color(0xFF7FAEF0),
    surface: Color(0xFF2E343E),
    isDark: true,
  );

  static Tokens of(BuildContext context) => Theme.of(context).extension<Tokens>() ?? light;

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(ThemeExtension<Tokens>? other, double t) => t < 0.5 || other is! Tokens ? this : other;
}

/// Off in tests: a running spinner never lets pumpAndSettle finish.
bool animateStatusSpinners = true;

/// The one corner radius for cards, fields, sheets and chips outside the kit's own pieces.
const kRadius = 4.0;

/// The muted red of a seat at its usage limit ("at usage limit · resets 2h"): not the alarm red, not working green.
Color limitColor(Tokens k) => Color.lerp(k.removed, k.muted, 0.4)!;

/// False while the window is not the focused, visible one: the looping
/// animations stop, so an idle app draws no frames.
final windowActive = ValueNotifier<bool>(true);

const fontSans = 'Inter';
const fontMono = 'JetBrains Mono';

/// Monospace text (paths, branches, ids), JetBrains Mono like the boards.
TextStyle mono(BuildContext context, {double size = 11, Color? color, FontWeight weight = FontWeight.w400}) =>
    TextStyle(
        fontFamily: fontMono,
        fontSize: size,
        fontWeight: weight,
        color: color ?? Tokens.of(context).muted,
        height: 1.4);

ThemeData buildTheme(Tokens k, Brightness b) {
  final scheme = ColorScheme(
    brightness: b,
    primary: k.ink,
    onPrimary: k.onInk,
    secondary: k.ink,
    onSecondary: k.onInk,
    error: k.accent,
    onError: k.onAccent,
    surface: k.ground,
    onSurface: k.ink,
    onSurfaceVariant: k.muted,
    outline: k.border,
    outlineVariant: k.divider,
    surfaceContainerLowest: k.ground,
    surfaceContainerLow: k.headerFill,
    surfaceContainer: k.fill,
    surfaceContainerHigh: k.fill,
    surfaceContainerHighest: k.fill,
    inverseSurface: k.ink,
    onInverseSurface: k.ground,
    shadow: Colors.black,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: fontSans,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: DesktopPageTransitions(),
      TargetPlatform.windows: DesktopPageTransitions(),
      TargetPlatform.linux: DesktopPageTransitions(),
    }),
  );
  // Spacing is never null: MaterialApp merges the M3 text geometry under this
  // theme, and a null would pick up its 0.5 tracking on body text.
  TextStyle s(double size, FontWeight w, {Color? color, double? height, double spacing = 0}) => TextStyle(
      fontFamily: fontSans,
      fontSize: size,
      fontWeight: w,
      color: color ?? k.ink,
      height: height,
      letterSpacing: spacing);
  final text = base.textTheme.copyWith(
    displaySmall: s(28, FontWeight.w700),
    headlineSmall: s(22, FontWeight.w700),
    titleLarge: s(16, FontWeight.w600),
    titleMedium: s(14, FontWeight.w600),
    titleSmall: s(13, FontWeight.w600),
    bodyLarge: s(14, FontWeight.w400, height: 1.5),
    bodyMedium: s(13, FontWeight.w400, height: 1.45),
    bodySmall: s(12, FontWeight.w400, color: k.muted),
    labelLarge: s(13, FontWeight.w600),
    labelMedium: s(12, FontWeight.w400, color: k.muted),
    labelSmall: s(12, FontWeight.w600, color: k.muted, spacing: 0.72),
  );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius));
  return base.copyWith(
    scaffoldBackgroundColor: k.ground,
    textTheme: text,
    extensions: [k],
    dividerTheme: DividerThemeData(color: k.divider, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: k.ground,
      foregroundColor: k.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: s(15, FontWeight.w600),
      shape: Border(bottom: BorderSide(color: k.border)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: k.ground,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected) ? s(11, FontWeight.w600) : s(11, FontWeight.w400, color: k.muted)),
      iconTheme: WidgetStateProperty.resolveWith(
          (st) => IconThemeData(size: 22, color: st.contains(WidgetState.selected) ? k.ink : k.muted)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Flutter makes buttons 8dp shorter on desktop by default; the sizes in sheetAction and compactAction are the real ones.
        visualDensity: VisualDensity.standard,
        backgroundColor: k.ink,
        foregroundColor: k.onInk,
        // M3's disabled look (the ink at 38% on 12%) is under 2:1 in the dark theme: muted on the fill reads, and is not ink.
        disabledBackgroundColor: k.fill,
        disabledForegroundColor: k.muted,
        minimumSize: const Size(44, 44),
        shape: rounded,
        textStyle: s(13, FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.standard,
        foregroundColor: k.ink,
        disabledForegroundColor: k.muted,
        minimumSize: const Size(44, 44),
        side: BorderSide(color: k.border),
        shape: rounded,
        textStyle: s(13, FontWeight.w400),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
          visualDensity: VisualDensity.standard, foregroundColor: k.ink, disabledForegroundColor: k.muted, minimumSize: const Size(44, 44), textStyle: s(13, FontWeight.w500)),
    ),
    iconButtonTheme:
        IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: k.ink, minimumSize: const Size(44, 44))),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: s(12, FontWeight.w400, color: k.muted),
      floatingLabelStyle: s(12, FontWeight.w400, color: k.muted),
      hintStyle: s(13, FontWeight.w400, color: k.muted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide(color: k.border)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide(color: k.border)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(kRadius), borderSide: BorderSide(color: k.ink, width: 1.5)),
    ),
    cardTheme: CardThemeData(
      color: k.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius), side: BorderSide(color: k.border)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: k.ground,
      side: BorderSide(color: k.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
      labelStyle: s(13, FontWeight.w500),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: k.ink,
      foregroundColor: k.onInk,
      elevation: 0,
      highlightElevation: 0,
      extendedTextStyle: s(13, FontWeight.w600),
      shape: rounded,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: k.surface,
      modalBarrierColor: Colors.black.withValues(alpha: k.isDark ? 0.7 : 0.4),
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: k.border,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(kRadius))),
    ),
    dialogTheme: DialogThemeData(backgroundColor: k.surface, surfaceTintColor: Colors.transparent, shape: rounded),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: k.ink,
      contentTextStyle: s(13, FontWeight.w400, color: k.onInk),
      behavior: SnackBarBehavior.floating,
      shape: rounded,
      actionTextColor: k.onInk,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? k.ink : null),
      checkColor: WidgetStatePropertyAll(k.onInk),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: k.ink, linearTrackColor: k.divider),
    listTileTheme: ListTileThemeData(
      titleTextStyle: s(13, FontWeight.w500),
      subtitleTextStyle: s(12, FontWeight.w400, color: k.muted),
      iconColor: k.ink,
    ),
  );
}

/// The two button sizes beyond the theme's 44: a full-width sheet action is 48 tall, an inline or desktop action 32
/// (its tap area still pads out to 48 on touch). Pass as `style:`; the theme supplies the rest.
const sheetAction = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(48)));
const compactAction = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(44, 32)), tapTargetSize: MaterialTapTargetSize.padded);
