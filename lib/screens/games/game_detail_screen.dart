import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../api/game_library.dart';
import '../../api/games_service.dart';
import '../../utils/app_theme.dart';

/// Detail page for an upcoming game: trailer (plays only after a tap),
/// screenshots, genres, description and a "+ Library" button.
class GameDetailScreen extends StatefulWidget {
  final GameInfo game;
  const GameDetailScreen({super.key, required this.game});

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
  late GameInfo _game = widget.game;
  bool _loadingDetails = false;
  String? _detailsError;
  bool _trailerStarted = false;
  Player? _player;
  VideoController? _video;

  @override
  void initState() {
    super.initState();
    GameLibrary.instance.load();
    if (!_game.detailsLoaded && _game.id.startsWith('steam:')) {
      _loadDetails();
    }
  }

  Future<void> _loadDetails() async {
    setState(() => _loadingDetails = true);
    try {
      final g = await SteamGames.details(_game);
      if (mounted) setState(() => _game = g);
    } catch (e) {
      if (mounted) setState(() => _detailsError = "Couldn't load details ($e)");
    } finally {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _startTrailer() {
    if (_trailerStarted) return;
    if (_game.trailerUrl != null) {
      final player = Player();
      _player = player;
      _video = VideoController(player);
      player.open(Media(_game.trailerUrl!), play: true);
    }
    setState(() => _trailerStarted = true);
  }

  Widget _trailer() {
    if (!_game.hasTrailer) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: !_trailerStarted
              ? GestureDetector(
                  onTap: _startTrailer,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: Colors.black),
                      if ((_game.trailerThumb ?? _game.cover) != null)
                        CachedNetworkImage(
                          imageUrl: (_game.trailerThumb ?? _game.cover)!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox(),
                        ),
                      const Center(
                        child: CircleAvatar(
                          radius: 30,
                          backgroundColor: Colors.black54,
                          child: Icon(Icons.play_arrow,
                              size: 40, color: Colors.white),
                        ),
                      ),
                      const Positioned(
                        left: 12,
                        bottom: 10,
                        child: Text('Tap to play trailer',
                            style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                    ],
                  ),
                )
              : (_video != null
                  ? Video(controller: _video!)
                  : InAppWebView(
                      initialData: InAppWebViewInitialData(
                        data: '<html><body style="margin:0;background:#000">'
                            '<iframe width="100%" height="100%" '
                            'style="position:absolute;inset:0;border:0" '
                            'src="https://www.youtube.com/embed/${_game.youtubeId}?autoplay=1&playsinline=1&rel=0" '
                            'allow="autoplay; encrypted-media; picture-in-picture; fullscreen" '
                            'allowfullscreen></iframe></body></html>',
                        baseUrl: WebUri('https://www.youtube.com'),
                        mimeType: 'text/html',
                        encoding: 'utf-8',
                      ),
                      initialSettings: InAppWebViewSettings(
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        javaScriptEnabled: true,
                      ),
                    )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    final lib = GameLibrary.instance;
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _trailer(),
          if (!_game.hasTrailer && g.cover != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CachedNetworkImage(
                    imageUrl: g.cover!,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox()),
              ),
            ),
          Text(g.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in g.platforms) _tag(p, AppTheme.current.primaryColor),
              for (final x in g.genres) _tag(x, Colors.white24),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.event, size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              Text(g.releaseDate.isEmpty ? 'TBA' : g.releaseDate,
                  style: const TextStyle(color: Colors.white70)),
              const Spacer(),
              ListenableBuilder(
                listenable: lib,
                builder: (_, _) {
                  final inLib = lib.contains(g.name);
                  return FilledButton.icon(
                    onPressed: inLib
                        ? null
                        : () async {
                            await lib.addInfo(g);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Added ${g.name} to your Library')));
                          },
                    icon: Icon(inLib ? Icons.check : Icons.add),
                    label: Text(inLib ? 'In Library' : 'Library'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loadingDetails)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator())),
          if (_detailsError != null)
            Text(_detailsError!,
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          if (g.description.isNotEmpty)
            Text(g.description,
                style: const TextStyle(color: Colors.white70, height: 1.45)),
          if (g.screenshots.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Screenshots',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: g.screenshots.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CachedNetworkImage(
                      imageUrl: g.screenshots[i],
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(color: Colors.white12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tag(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 11)),
      );
}
