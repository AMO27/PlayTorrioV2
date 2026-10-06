import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../api/games_service.dart';
import '../../utils/app_theme.dart';
import 'game_detail_screen.dart';

/// Upcoming tab: popular unreleased games (PC from Steam, consoles from
/// IGDB when keys are saved), most popular first.
class GamesUpcomingTab extends StatefulWidget {
  const GamesUpcomingTab({super.key});

  @override
  State<GamesUpcomingTab> createState() => _GamesUpcomingTabState();
}

class _GamesUpcomingTabState extends State<GamesUpcomingTab>
    with AutomaticKeepAliveClientMixin {
  List<GameInfo> _games = [];
  bool _loading = true;
  final List<String> _notes = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _notes.clear();
    });
    var steam = <GameInfo>[];
    var igdb = <GameInfo>[];
    final hasKey = await IgdbGames.hasCredentials();
    await Future.wait([
      () async {
        try {
          steam = await SteamGames.comingSoon();
        } catch (e) {
          _notes.add("Couldn't load PC games from Steam ($e).");
        }
      }(),
      () async {
        if (!hasKey) return;
        try {
          igdb = await IgdbGames.upcoming();
        } catch (e) {
          _notes.add("Couldn't load console games from IGDB ($e).");
        }
      }(),
    ]);
    if (!hasKey) {
      _notes.add(
          'Showing PC games only. For console games, add a free IGDB key in Settings > Games.');
    }
    // Interleave so both lists stay in popularity order.
    final merged = <GameInfo>[];
    for (var i = 0; i < steam.length || i < igdb.length; i++) {
      if (i < steam.length) merged.add(steam[i]);
      if (i < igdb.length) merged.add(igdb[i]);
    }
    if (!mounted) return;
    setState(() {
      _games = merged;
      _loading = false;
    });
  }

  Color _dateColor(String d) {
    final l = d.toLowerCase();
    if (l.startsWith('out now') || l.contains('(out now)')) {
      return Colors.greenAccent;
    }
    if (l == 'tba' || l == 'coming soon') return Colors.orangeAccent;
    return Colors.white70;
  }

  Widget _card(GameInfo g) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GameDetailScreen(game: g))),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: g.cover == null
                  ? Container(color: Colors.white12)
                  : CachedNetworkImage(
                      imageUrl: g.cover!,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorWidget: (_, _, _) => Container(
                          color: Colors.white12,
                          child: const Icon(Icons.sports_esports,
                              color: Colors.white38)),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: g.platforms
                        .take(4)
                        .map((p) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppTheme.current.primaryColor
                                    .withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(p,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 10)),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 4),
                  Text(g.releaseDate,
                      style: TextStyle(
                          color: _dateColor(g.releaseDate), fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Most popular first',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Refresh',
                    onPressed: _load,
                  ),
                ],
              ),
            ),
          ),
          for (final n in _notes)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Text(n,
                    style: const TextStyle(
                        color: Colors.orangeAccent, fontSize: 12)),
              ),
            ),
          if (_games.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text('No upcoming games found. Pull down to retry.',
                    style: TextStyle(color: Colors.white54)),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 200,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _card(_games[i]),
                  childCount: _games.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
