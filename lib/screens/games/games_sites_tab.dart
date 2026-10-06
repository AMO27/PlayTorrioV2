import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../utils/app_theme.dart';
import 'games_browser.dart';
import 'saved_sites_store.dart';

/// A tab made of saved-site tiles. Tapping a tile opens the site in the
/// in-app browser; the star in the browser saves or removes the current page.
/// Used by Play now and by Download later, each with its own [store].
class GamesSitesTab extends StatefulWidget {
  final SavedSitesStore store;
  final String intro;
  final void Function(DownloadStartRequest request, Map<String, String> headers)?
      onDownload;
  const GamesSitesTab(
      {super.key, required this.store, required this.intro, this.onDownload});

  @override
  State<GamesSitesTab> createState() => _GamesSitesTabState();
}

class _GamesSitesTabState extends State<GamesSitesTab>
    with AutomaticKeepAliveClientMixin {
  List<SavedSite> _sites = [];
  bool _loaded = false;
  String? _openUrl;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.store.load().then((s) {
      if (!mounted) return;
      setState(() {
        _sites = s;
        _loaded = true;
      });
    });
  }

  bool _isSaved(String url) {
    final n = SavedSite.normalize(url);
    return _sites.any((s) => SavedSite.normalize(s.url) == n);
  }

  void _toggleSave(String title, String url) {
    final n = SavedSite.normalize(url);
    final idx = _sites.indexWhere((s) => SavedSite.normalize(s.url) == n);
    setState(() {
      if (idx >= 0) {
        _sites.removeAt(idx);
      } else {
        _sites.add(SavedSite(title, url));
      }
    });
    widget.store.save(_sites);
  }

  /// Shows a snackbar with Undo that closes by itself after 5 seconds.
  void _undoSnack(String text, VoidCallback undo) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final c = messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 5),
      action: SnackBarAction(label: 'UNDO', onPressed: undo),
    ));
    Timer(const Duration(seconds: 5), () {
      try {
        c.close();
      } catch (_) {}
    });
  }

  Future<void> _rename(SavedSite site) async {
    final ctrl = TextEditingController(text: site.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => site.name = name);
    widget.store.save(_sites);
  }

  void _remove(SavedSite site) {
    final idx = _sites.indexOf(site);
    if (idx < 0) return;
    setState(() => _sites.removeAt(idx));
    widget.store.save(_sites);
    _undoSnack('Removed ${site.name}', () {
      setState(() => _sites.insert(idx.clamp(0, _sites.length), site));
      widget.store.save(_sites);
    });
  }

  Future<void> _addByUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a site'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'example.com'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    final full = url.contains('://') ? url : 'https://$url';
    final host = Uri.tryParse(full)?.host ?? '';
    if (host.isEmpty || !host.contains('.')) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("That doesn't look like a web address")));
      }
      return;
    }
    if (_isSaved(full)) {
      setState(() => _openUrl = full);
      return;
    }
    setState(() {
      _sites.add(SavedSite(host.replaceFirst(RegExp(r'^www\.'), ''), full));
      _openUrl = full;
    });
    widget.store.save(_sites);
  }

  Widget _tile(SavedSite s) {
    final host = Uri.tryParse(s.url)?.host ?? '';
    return SizedBox(
      width: 170,
      child: Card(
        color: Colors.white10,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _openUrl = s.url),
          onLongPress: () => _rename(s),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    'https://www.google.com/s2/favicons?domain=$host&sz=64',
                    width: 28,
                    height: 28,
                    errorBuilder: (_, _, _) => Icon(Icons.public,
                        size: 28, color: AppTheme.current.primaryColor),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                      Text(host.replaceFirst(RegExp(r'^www\.'), ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: Colors.white54),
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    if (v == 'rename') _rename(s);
                    if (v == 'remove') _remove(s);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_openUrl != null) {
      return GamesBrowser(
        key: ValueKey(_openUrl),
        initialUrl: _openUrl!,
        isSaved: _isSaved,
        onToggleSave: _toggleSave,
        onClose: () => setState(() => _openUrl = null),
        onDownload: widget.onDownload,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(widget.intro,
            style: const TextStyle(color: Colors.white60, fontSize: 13)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ..._sites.map(_tile),
            SizedBox(
              width: 170,
              child: OutlinedButton.icon(
                onPressed: _addByUrl,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add site'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white24),
                  minimumSize: const Size(170, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
