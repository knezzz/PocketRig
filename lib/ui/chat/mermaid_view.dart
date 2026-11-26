import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../web_backdrop.dart';

import '../kit.dart' show Panel;
import '../theme.dart';

/// mermaid.js from a CDN (the phone has internet; the diagram source never
/// leaves it, rendering happens in the WebView).
const mermaidScript = 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js';

/// The page a mermaid block renders in. It reports its height through the
/// `Size` channel so the chat can size the WebView to the diagram.
String mermaidHtml(String source, {required bool dark, required Tokens k, bool fullscreen = false}) {
  final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(source);
  String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  final bg = hex(k.ground);
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1${fullscreen ? '' : ', maximum-scale=1'}">
<style>html,body{margin:0;padding:0;background:$bg}#d{padding:8px;display:flex;justify-content:center}
svg{max-width:100%;height:auto}.err{font:13px monospace;color:${hex(k.accent)};white-space:pre-wrap;padding:8px}</style>
<script src="$mermaidScript"></script></head>
<body><div id="d"><pre class="mermaid">$escaped</pre></div>
<script>
function report(){ try { Size.postMessage(String(document.body.scrollHeight)); } catch(e) {} }
if (window.mermaid) {
  mermaid.initialize({startOnLoad:false, theme:'${dark ? 'dark' : 'default'}', securityLevel:'strict'});
  mermaid.run({querySelector:'.mermaid'}).then(report).catch(function(e){
    document.getElementById('d').innerHTML='<div class="err">'+String(e && e.message || e).replace(/</g,'&lt;')+'</div>'; report();
  });
} else {
  document.getElementById('d').innerHTML='<div class="err">Couldn\\'t load mermaid.js (offline?)</div>'; report();
}
</script></body></html>''';
}

/// A ```mermaid block rendered inline, with a button to open it full screen.
class MermaidView extends StatefulWidget {
  const MermaidView(this.source, {super.key});
  final String source;

  /// Off under test, where there is no WebView: the figure shows the
  /// diagram source instead.
  @visibleForTesting
  static bool useWebView = true;
  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView> {
  bool get useWebView => MermaidView.useWebView;

  WebViewController? _ctrl;
  double _height = 180;
  bool _ready = false;
  bool? _dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!useWebView) return;
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark == dark && _ctrl != null) return;
    _dark = dark;
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Size', onMessageReceived: (m) {
        final h = double.tryParse(m.message);
        if (h != null && mounted) {
          setState(() {
            _height = h.clamp(80, 640);
            _ready = true;
          });
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        // Links in diagrams must not navigate the inline view.
        onNavigationRequest: (r) => r.url.startsWith('about:') || r.url.startsWith('data:')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadHtmlString(mermaidHtml(widget.source, dark: dark, k: Tokens.of(context)));
    setWebBackdrop(_ctrl!, Colors.transparent);
  }

  @override
  Widget build(BuildContext context) {
    final k = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Panel(
      // The old box's 1dp border was padding; Panel's is not.
      padding: const EdgeInsets.fromLTRB(13, 5, 13, 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Diagram · mermaid', style: TextStyle(fontSize: 12, color: k.muted))),
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => MermaidFullScreen(widget.source),
            )),
            style: TextButton.styleFrom(textStyle: const TextStyle(fontFamily: fontSans, fontSize: 12, decoration: TextDecoration.underline)),
            child: const Text('Full screen'),
          ),
        ]),
        ClipRRect(
          borderRadius: BorderRadius.circular(kRadius),
          child: useWebView
              ? SizedBox(
                  height: _height,
                  child: Stack(children: [
                    WebViewWidget(controller: _ctrl!),
                    if (!_ready) const Center(child: CircularProgressIndicator()),
                  ]))
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  color: k.fill,
                  child: Text(widget.source, style: mono(context, size: 11, color: k.ink)),
                ),
        ),
      ]),
      ),
    );
  }
}

class MermaidFullScreen extends StatelessWidget {
  const MermaidFullScreen(this.source, {super.key});
  final String source;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Size', onMessageReceived: (_) {})
      ..loadHtmlString(mermaidHtml(source, dark: dark, k: Tokens.of(context), fullscreen: true));
    return Scaffold(
      appBar: AppBar(title: const Text('Diagram')),
      body: WebViewWidget(
        controller: ctrl,
        gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer())},
      ),
    );
  }
}
