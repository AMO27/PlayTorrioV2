import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/comic_download_service.dart';
import '../api/comics_service.dart';
import 'comic_reader_screen.dart';

/// Comics > Downloads: everything saved by the app, readable offline.
class ComicDownloadsScreen extends StatefulWidget {
  const ComicDownloadsScreen({super.key});

  @override
  State<ComicDownloadsScreen> createState() => _ComicDownloadsScreenState();
}

class _ComicDownloadsScreenState extends State<ComicDownloadsScreen> {
  List<DownloadedComic>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ComicDownloadService.instance.list();
    if (mounted) setState(() => _items = items);
  }

  void _open(DownloadedComic d) {
    if (d.isFolder) {
      final chapter = ComicChapter(title: d.chapter, url: 'local:${d.path}', dateAdded: '');
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ComicReaderScreen(
            chapterTitle: d.chapter,
            chapterUrl: chapter.url,
            chapters: [chapter],
            currentChapterIndex: 0,
            comic: d.comic,
          ),
        ),
      );
    } else {
      // Archives / PDFs open in whatever app handles them on this device.
      launchUrl(Uri.file(d.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Comic downloads')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing downloaded yet. Open a comic and tap the download arrow next to an issue.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                  itemBuilder: (context, i) {
                    final d = items[i];
                    return ListTile(
                      leading: Icon(d.isFolder ? Icons.menu_book : Icons.insert_drive_file,
                          color: Colors.white70),
                      title: Text(d.chapter, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        d.isFolder ? '${d.title} · ${d.pages} pages' : d.title,
                        style: const TextStyle(color: Colors.white54),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.white54),
                        tooltip: 'Delete download',
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: const Text('Delete this download?'),
                              content: Text(d.chapter),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Cancel')),
                                TextButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await ComicDownloadService.instance.delete(d);
                            _load();
                          }
                        },
                      ),
                      onTap: () => _open(d),
                    );
                  },
                ),
    );
  }
}
