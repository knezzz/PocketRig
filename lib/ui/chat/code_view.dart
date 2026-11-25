import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../theme.dart';

/// Only the languages a coding agent usually touches, to keep the app small.
final Highlight _hl = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'go': langGo,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

/// Fence tags and file extensions → registered language names.
String? languageFor(String? tagOrPath) {
  if (tagOrPath == null || tagOrPath.isEmpty) return null;
  final t = tagOrPath.contains('.') || tagOrPath.contains('/')
      ? tagOrPath.split('/').last.split('.').last.toLowerCase()
      : tagOrPath.toLowerCase();
  return switch (t) {
    'sh' || 'bash' || 'zsh' || 'console' => 'bash',
    'shell' => 'shell',
    'js' || 'jsx' || 'mjs' || 'cjs' || 'javascript' => 'javascript',
    'ts' || 'tsx' || 'typescript' => 'typescript',
    'py' || 'python' => 'python',
    'rb' || 'ruby' => 'ruby',
    'rs' || 'rust' => 'rust',
    'kt' || 'kts' || 'kotlin' => 'kotlin',
    'yml' || 'yaml' => 'yaml',
    'md' || 'markdown' => 'markdown',
    'html' || 'htm' || 'xml' || 'svg' || 'plist' => 'xml',
    'patch' || 'diff' => 'diff',
    'dart' || 'go' || 'java' || 'json' || 'css' || 'sql' || 'swift' => t,
    _ => null,
  };
}

TextSpan highlightSpan(String code, String? language, TextStyle base, {required bool dark}) {
  final lang = languageFor(language);
  if (lang == null || code.length > 200000) return TextSpan(text: code, style: base);
  try {
    final result = _hl.highlight(code: code, language: lang);
    final renderer = TextSpanRenderer(base, dark ? githubDarkTheme : githubTheme);
    result.render(renderer);
    return renderer.span ?? TextSpan(text: code, style: base);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
}

/// A highlighted code block that scrolls sideways, with a copy button.
class CodeView extends StatelessWidget {
  const CodeView(this.code, {super.key, this.language, this.selectable = false});
  final String code;
  final String? language;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = TextStyle(fontFamily: fontMono, fontSize: 12.5, height: 1.35, color: k.ink);
    final span = highlightSpan(code, language, base, dark: dark);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 48), // room for the copy button
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: k.fill, borderRadius: BorderRadius.circular(kRadius)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 44, 10),
          child: selectable ? SelectableText.rich(span) : Text.rich(span, softWrap: false),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            tooltip: 'Copy code',
            iconSize: 18,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 2)));
              }
            },
            icon: const Icon(Icons.copy),
          ),
        ),
      ]),
    );
  }
}
