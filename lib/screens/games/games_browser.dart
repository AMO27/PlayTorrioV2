import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../utils/app_theme.dart';
import 'saved_sites_store.dart';

/// In-app browser used by the Play and Download tabs: address bar,
/// back / forward / reload, and a star that saves the current page.
class GamesBrowser extends StatefulWidget {
  final String initialUrl;
  final bool Function(String url) isSaved;
  final void Function(String title, String url) onToggleSave;
  final VoidCallback onClose;

  /// Download tab only: called when a page starts a file download. The app
  /// takes over the download (the webview's own download is cancelled).
  final void Function(DownloadStartRequest request, Map<String, String> headers)?
      onDownload;

  const GamesBrowser({
    super.key,
    required this.initialUrl,
    required this.isSaved,
    required this.onToggleSave,
    required this.onClose,
    this.onDownload,
  });

  @override
  State<GamesBrowser> createState() => _GamesBrowserState();
}

class _GamesBrowserState extends State<GamesBrowser> {
  InAppWebViewController? _ctrl;
  final _addr = TextEditingController();
  final _addrFocus = FocusNode();
  String _url = '';
  String _title = '';
  double _progress = 0;
  bool _loading = false;
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl;
    _addr.text = _url;
  }

  @override
  void dispose() {
    _addr.dispose();
    _addrFocus.dispose();
    super.dispose();
  }

  /// Turns what the user typed into a URL: a host becomes https://host,
  /// anything else becomes a web search.
  String _toUrl(String input) {
    final t = input.trim();
    if (t.isEmpty) return _url;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(t)) return t;
    if (!t.contains(' ') && t.contains('.')) return 'https://$t';
    return 'https://duckduckgo.com/?q=${Uri.encodeQueryComponent(t)}';
  }

  void _go(String input) {
    final url = _toUrl(input);
    _ctrl?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    _addrFocus.unfocus();
  }

  Future<void> _refreshNav() async {
    final c = _ctrl;
    if (c == null) return;
    final b = await c.canGoBack();
    final f = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      _canBack = b;
      _canForward = f;
    });
  }

  Widget _barButton(IconData icon, String tip, VoidCallback? onTap,
      {Color? color}) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tip,
      color: color ?? Colors.white,
      disabledColor: Colors.white24,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.isSaved(_url);
    return Column(
      children: [
        Container(
          color: Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              _barButton(Icons.grid_view_rounded, 'Saved sites', widget.onClose),
              _barButton(Icons.arrow_back, 'Back',
                  _canBack ? () => _ctrl?.goBack() : null),
              _barButton(Icons.arrow_forward, 'Forward',
                  _canForward ? () => _ctrl?.goForward() : null),
              _barButton(
                _loading ? Icons.close : Icons.refresh,
                _loading ? 'Stop' : 'Reload',
                () => _loading ? _ctrl?.stopLoading() : _ctrl?.reload(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _addr,
                    focusNode: _addrFocus,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    textInputAction: TextInputAction.go,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    onSubmitted: _go,
                    onTap: () => _addr.selection = TextSelection(
                        baseOffset: 0, extentOffset: _addr.text.length),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white10,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      hintText: 'Type a web address',
                      hintStyle:
                          const TextStyle(color: Colors.white38, fontSize: 13),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
              _barButton(
                saved ? Icons.star_rounded : Icons.star_border_rounded,
                saved ? 'Remove from saved sites' : 'Save this site',
                () {
                  final name = _title.trim().isNotEmpty
                      ? _title.trim()
                      : (Uri.tryParse(_url)?.host ?? _url);
                  widget.onToggleSave(name, _url);
                  setState(() {});
                },
                color: saved ? Colors.amber : Colors.white,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 2,
          child: _loading
              ? LinearProgressIndicator(
                  value: _progress > 0 && _progress < 1 ? _progress : null,
                  backgroundColor: Colors.transparent,
                  color: AppTheme.current.primaryColor,
                )
              : null,
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              supportMultipleWindows: false,
              javaScriptCanOpenWindowsAutomatically: false,
              useOnDownloadStart: widget.onDownload != null,
            ),
            onWebViewCreated: (c) => _ctrl = c,
            onLoadStart: (_, url) {
              if (!mounted) return;
              setState(() {
                _loading = true;
                if (url != null) {
                  _url = url.toString();
                  if (!_addrFocus.hasFocus) _addr.text = _url;
                }
              });
            },
            onLoadStop: (c, url) async {
              final t = await c.getTitle();
              if (!mounted) return;
              setState(() {
                _loading = false;
                _title = t ?? '';
                if (url != null) {
                  _url = url.toString();
                  if (!_addrFocus.hasFocus) _addr.text = _url;
                }
              });
              _refreshNav();
            },
            onDownloadStarting: widget.onDownload == null
                ? null
                : (c, req) async {
                    final headers = <String, String>{'Referer': _url};
                    final ua = req.userAgent;
                    if (ua != null && ua.isNotEmpty) headers['User-Agent'] = ua;
                    try {
                      final cookies =
                          await CookieManager.instance().getCookies(url: req.url);
                      if (cookies.isNotEmpty) {
                        headers['Cookie'] = cookies
                            .map((k) => '${k.name}=${k.value}')
                            .join('; ');
                      }
                    } catch (_) {}
                    widget.onDownload!(req, headers);
                    return DownloadStartResponse(
                        handled: true,
                        action: DownloadStartResponseAction.CANCEL);
                  },
            onProgressChanged: (_, p) {
              if (mounted) setState(() => _progress = p / 100);
            },
            onUpdateVisitedHistory: (_, url, _) {
              if (url != null && mounted) {
                setState(() {
                  _url = url.toString();
                  if (!_addrFocus.hasFocus) _addr.text = _url;
                });
              }
              _refreshNav();
            },
          ),
        ),
      ],
    );
  }
}
