import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import '../utils/app_theme.dart';

// ─── Providers ───────────────────────────────────────────────────────────────
//
// The old sources (PPV.to, dami-tv.pro, cdn-live.tv) are gone: the first two
// were seized in "Operation Offsides" and cdn-live.tv no longer resolves.
// These are the replacements. All three hand back embeddable player pages,
// which we load in a WebView like before.

enum _DataProvider { damiTv, sportsBite, ntvStream }

extension on _DataProvider {
  String get label => switch (this) {
        _DataProvider.damiTv => 'Dami TV',
        _DataProvider.sportsBite => 'SportsBite',
        _DataProvider.ntvStream => 'NTV Stream',
      };

  String get chipLabel => switch (this) {
        _DataProvider.damiTv => '📺 Dami TV',
        _DataProvider.sportsBite => '⚡ SportsBite',
        _DataProvider.ntvStream => '🎬 NTV Stream',
      };

  Color get color => switch (this) {
        _DataProvider.damiTv => Colors.blue,
        _DataProvider.sportsBite => Colors.orange,
        _DataProvider.ntvStream => Colors.teal,
      };
}

// ─── Models ──────────────────────────────────────────────────────────────────

class _Sport {
  final String id;
  final String name;
  const _Sport({required this.id, required this.name});
}

/// One playable server/mirror for an event.
class _StreamOption {
  final String label;
  final String url;
  const _StreamOption({required this.label, required this.url});
}

/// Provider-agnostic event shown in the grid.
class _LiveEvent {
  final String id;
  final String title;
  final String category; // pretty sport/category name, used for tabs
  final String league;
  final String? poster;
  final String? homeTeam;
  final String? homeBadge;
  final String? awayTeam;
  final String? awayBadge;
  final bool isLive;
  final bool alwaysOn; // 24/7 channel rather than a scheduled match
  final DateTime? start;
  final int viewers;
  final List<_StreamOption> sources;

  const _LiveEvent({
    required this.id,
    required this.title,
    required this.category,
    this.league = '',
    this.poster,
    this.homeTeam,
    this.homeBadge,
    this.awayTeam,
    this.awayBadge,
    this.isLive = false,
    this.alwaysOn = false,
    this.start,
    this.viewers = 0,
    required this.sources,
  });

  bool get hasTeams =>
      (homeTeam?.isNotEmpty ?? false) && (awayTeam?.isNotEmpty ?? false);

  String get timeLabel {
    if (alwaysOn) return '🔴 24/7';
    if (isLive) return '🔴 Live Now';
    final s = start;
    if (s == null) return '';
    final local = s.toLocal();
    final now = DateTime.now();
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (local.isBefore(now)) return '';
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (sameDay) return '⏰ $hm';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '⏰ ${days[local.weekday - 1]} $hm';
  }
}

// ─── Parsing helpers ─────────────────────────────────────────────────────────

String _str(dynamic v) => v == null ? '' : v.toString();

String? _absUrl(dynamic v, String origin) {
  final s = _str(v).trim();
  if (s.isEmpty) return null;
  if (s.startsWith('//')) return 'https:$s';
  if (s.startsWith('/')) return '$origin$s';
  return s;
}

/// "american-football" -> "American Football"
String _prettyCategory(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 'Other';
  return s
      .split(RegExp(r'[-_\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

DateTime? _fromMs(dynamic v) {
  if (v is num && v > 0) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
  }
  return null;
}

String? _teamName(dynamic teams, String side) {
  if (teams is! Map) return null;
  final t = teams[side];
  if (t is! Map) return null;
  final n = _str(t['name']).trim();
  return n.isEmpty ? null : n;
}

String? _teamBadge(dynamic teams, String side, String origin) {
  if (teams is! Map) return null;
  final t = teams[side];
  if (t is! Map) return null;
  return _absUrl(t['badge'], origin);
}

/// Live first, then upcoming by start time, then everything else.
void _sortEvents(List<_LiveEvent> events) {
  int rank(_LiveEvent e) => e.isLive && !e.alwaysOn ? 0 : (e.alwaysOn ? 2 : 1);
  events.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    final sa = a.start, sb = b.start;
    if (sa != null && sb != null) return sa.compareTo(sb);
    if (sa != null) return -1;
    if (sb != null) return 1;
    return a.title.compareTo(b.title);
  });
}

// ─── API ─────────────────────────────────────────────────────────────────────

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

Future<dynamic> _getJson(String url, {required String origin}) async {
  final host = Uri.parse(url).host;
  String problem = '$host: unknown error';
  try {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': _userAgent,
      'Accept': 'application/json, text/plain, */*',
      'Referer': '$origin/',
      'Origin': origin,
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 200) {
      try {
        return jsonDecode(resp.body);
      } catch (_) {
        problem = '$host did not return match data (possibly blocked)';
      }
    } else {
      problem = '$host returned HTTP ${resp.statusCode}';
    }
  } catch (e) {
    problem = '$host: $e';
  }

  // These sites sit behind Cloudflare. If the plain request got a bot
  // challenge instead of JSON, load it in a hidden browser, which can pass
  // the challenge, and read the JSON out of the page.
  final viaBrowser = await _getJsonViaWebView(url);
  if (viaBrowser != null) return viaBrowser;
  throw Exception(problem);
}

Future<dynamic> _getJsonViaWebView(String url) async {
  final completer = Completer<String>();
  HeadlessInAppWebView? view;
  try {
    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent: _userAgent,
      ),
      onLoadStop: (ctrl, _) async {
        // Challenge pages reload themselves, so poll until the body is JSON.
        for (var i = 0; i < 20 && !completer.isCompleted; i++) {
          final body = await ctrl.evaluateJavascript(
              source: 'document.body ? document.body.innerText : ""');
          final text = body?.toString() ?? '';
          final t = text.trimLeft();
          if (t.startsWith('{') || t.startsWith('[')) {
            if (!completer.isCompleted) completer.complete(text);
            return;
          }
          await Future.delayed(const Duration(milliseconds: 750));
        }
      },
    );
    await view.run();
    final text = await completer.future.timeout(const Duration(seconds: 25));
    return jsonDecode(text);
  } catch (_) {
    return null;
  } finally {
    try {
      await view?.dispose();
    } catch (_) {}
  }
}

// damitv.st — GET /papi/matches/live returns a flat list:
// { id, league, title, category, date(ms), poster, teams{home,away{name,badge}},
//   status, viewers, embedUrl, substreams[] }
Future<List<_LiveEvent>> _fetchDamiTv() async {
  const origin = 'https://damitv.st';
  final data = await _getJson('$origin/papi/matches/live', origin: origin);
  final list = data is List
      ? data
      : (data is Map ? (data['matches'] ?? data['data'] ?? []) : []) as List;

  final out = <_LiveEvent>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    final sources = <_StreamOption>[];
    final main = _absUrl(raw['embedUrl'], origin);
    if (main != null) sources.add(_StreamOption(label: 'Main', url: main));

    // substreams: alternate mirrors; shape isn't guaranteed, so be lenient.
    final subs = raw['substreams'];
    if (subs is List) {
      var n = 2;
      for (final s in subs) {
        String? url;
        String label = 'Server $n';
        if (s is String) {
          url = _absUrl(s, origin);
        } else if (s is Map) {
          url = _absUrl(s['embedUrl'] ?? s['url'] ?? s['iframe'], origin);
          final l = _str(s['label'] ?? s['name'] ?? s['title']).trim();
          if (l.isNotEmpty) label = l;
        }
        final u = url;
        if (u != null && !sources.any((o) => o.url == u)) {
          sources.add(_StreamOption(label: label, url: u));
          n++;
        }
      }
    }

    final id = _str(raw['id']);
    final status = _str(raw['status']).toLowerCase();
    out.add(_LiveEvent(
      id: id,
      title: _str(raw['title']).isNotEmpty ? _str(raw['title']) : id,
      category: _prettyCategory(_str(raw['category'])),
      league: _str(raw['league']),
      poster: _absUrl(raw['poster'], origin),
      homeTeam: _teamName(raw['teams'], 'home'),
      homeBadge: _teamBadge(raw['teams'], 'home', origin),
      awayTeam: _teamName(raw['teams'], 'away'),
      awayBadge: _teamBadge(raw['teams'], 'away', origin),
      isLive: status == 'live',
      alwaysOn: id.startsWith('247-'),
      start: _fromMs(raw['date']),
      viewers: raw['viewers'] is num ? (raw['viewers'] as num).toInt() : 0,
      sources: sources,
    ));
  }
  _sortEvents(out);
  return out;
}

// sportsbite.org — GET /api/forestgump/matches returns
// { days: [ { date, events: [ { title, slug, start(ISO), category, sport,
//   teams{home,away{name}}, poster, live, streams:[{label, manifest_url,
//   format:"iframe", status, quality}] } ] } ], ... }
Future<List<_LiveEvent>> _fetchSportsBite() async {
  const origin = 'https://sportsbite.org';
  final data =
      await _getJson('$origin/api/forestgump/matches', origin: origin);
  final days = data is Map ? data['days'] : null;
  if (days is! List) return [];

  final seen = <String>{};
  final out = <_LiveEvent>[];
  for (final day in days) {
    if (day is! Map) continue;
    final events = day['events'];
    if (events is! List) continue;
    for (final raw in events) {
      if (raw is! Map) continue;
      final id = _str(raw['slug']).isNotEmpty
          ? _str(raw['slug'])
          : _str(raw['streamed_event_id']);
      if (id.isEmpty || !seen.add(id)) continue;

      final sources = <_StreamOption>[];
      final streams = raw['streams'];
      if (streams is List) {
        for (final s in streams) {
          if (s is! Map) continue;
          final format = _str(s['format']).toLowerCase();
          final hints = s['playback_hints'];
          final player = hints is Map ? _str(hints['player']).toLowerCase() : '';
          // Only page/iframe embeds can be shown in the WebView.
          if (format.isNotEmpty && format != 'iframe' && player != 'iframe') {
            continue;
          }
          if (_str(s['status']).toLowerCase() == 'offline') continue;
          final url = _absUrl(s['manifest_url'] ?? s['url'], origin);
          if (url == null || sources.any((o) => o.url == url)) continue;
          var label = _str(s['label'] ?? s['name']).trim();
          if (label.isEmpty) label = 'Server ${sources.length + 1}';
          final quality = _str(s['quality']).trim();
          final lang = _str(s['language']).trim();
          final extra = [quality, lang].where((x) => x.isNotEmpty).join(' · ');
          sources.add(_StreamOption(
              label: extra.isEmpty ? label : '$label  ($extra)', url: url));
        }
      }

      final start = DateTime.tryParse(_str(raw['start']));
      // Always-on channels come back with a 1970 epoch start time.
      final alwaysOn = start != null && start.year < 2000;
      final cat = _str(raw['sport']).isNotEmpty
          ? _str(raw['sport'])
          : _str(raw['category']);

      out.add(_LiveEvent(
        id: id,
        title: _str(raw['title']).isNotEmpty ? _str(raw['title']) : id,
        category: _prettyCategory(cat),
        poster: _absUrl(raw['poster'], origin),
        homeTeam: _teamName(raw['teams'], 'home'),
        awayTeam: _teamName(raw['teams'], 'away'),
        isLive: raw['live'] == true,
        alwaysOn: alwaysOn,
        start: alwaysOn ? null : start,
        sources: sources,
      ));
    }
  }
  _sortEvents(out);
  return out;
}

// ntv.cx (NTV Stream) — GET /api/get-matches returns
// { success, all: [ { id, title, category, date(ms), poster, teams,
//   sources:[{source, id}], live } ] }
// The event has no embed URL; the site's own player page is
// /watch/<server>/<sources[].id>, where <server> is one of its mirrors.
const _ntvServers = ['kobra', 'falcon', 'raptor', 'phoenix', 'titan'];

Future<List<_LiveEvent>> _fetchNtvStream() async {
  const origin = 'https://ntv.cx';
  final data = await _getJson('$origin/api/get-matches', origin: origin);
  final list = data is Map ? (data['all'] ?? data['matches']) : data;
  if (list is! List) return [];

  final out = <_LiveEvent>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    final id = _str(raw['id']);

    final streamIds = <String>[];
    final srcs = raw['sources'];
    if (srcs is List) {
      for (final s in srcs) {
        final sid = s is Map ? _str(s['id']) : _str(s);
        if (sid.isNotEmpty && !streamIds.contains(sid)) streamIds.add(sid);
      }
    }
    if (streamIds.isEmpty && id.isNotEmpty) streamIds.add(id);

    final sources = <_StreamOption>[];
    for (var i = 0; i < streamIds.length; i++) {
      final sid = Uri.encodeComponent(streamIds[i]);
      final prefix = streamIds.length > 1 ? 'Feed ${i + 1} · ' : '';
      for (final server in _ntvServers) {
        final name = server[0].toUpperCase() + server.substring(1);
        sources.add(_StreamOption(
          label: '$prefix$name',
          url: '$origin/watch/$server/$sid',
        ));
      }
    }

    out.add(_LiveEvent(
      id: id,
      title: _str(raw['title']).isNotEmpty ? _str(raw['title']) : id,
      category: _prettyCategory(_str(raw['category'])),
      poster: _absUrl(raw['poster'], origin),
      homeTeam: _teamName(raw['teams'], 'home'),
      homeBadge: _teamBadge(raw['teams'], 'home', origin),
      awayTeam: _teamName(raw['teams'], 'away'),
      awayBadge: _teamBadge(raw['teams'], 'away', origin),
      isLive: raw['live'] == true,
      start: _fromMs(raw['date']),
      sources: sources,
    ));
  }
  _sortEvents(out);
  return out;
}

Future<List<_LiveEvent>> _fetchFor(_DataProvider p) => switch (p) {
      _DataProvider.damiTv => _fetchDamiTv(),
      _DataProvider.sportsBite => _fetchSportsBite(),
      _DataProvider.ntvStream => _fetchNtvStream(),
    };

// ═════════════════════════════════════════════════════════════════════════════
//  MAIN SCREEN
// ═════════════════════════════════════════════════════════════════════════════

class LiveMatchesScreen extends StatefulWidget {
  const LiveMatchesScreen({super.key});

  @override
  State<LiveMatchesScreen> createState() => _LiveMatchesScreenState();
}

class _LiveMatchesScreenState extends State<LiveMatchesScreen>
    with TickerProviderStateMixin {
  List<_Sport> _sports = [];
  bool _loading = true;
  String? _error;
  String _sportFilter = 'all';
  bool _liveOnly = false;

  TabController? _tabController;
  _DataProvider _provider = _DataProvider.damiTv;
  List<_LiveEvent> _events = [];
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final provider = _provider;
    setState(() {
      _loading = true;
      _error = null;
      _sportFilter = 'all';
    });
    try {
      final events = await _fetchFor(provider);
      // Ignore results if the user switched provider mid-load.
      if (!mounted || token != _loadToken) return;

      final seen = <String>{};
      final cats = <_Sport>[];
      for (final e in events) {
        if (seen.add(e.category)) cats.add(_Sport(id: e.category, name: e.category));
      }
      cats.sort((a, b) => a.name.compareTo(b.name));

      final oldCtrl = _tabController;
      setState(() {
        _tabController = null;
        _events = events;
        _sports = cats;
        _loading = false;
      });
      oldCtrl?.dispose();

      final newCtrl = TabController(length: cats.length + 1, vsync: this);
      newCtrl.addListener(() {
        if (!newCtrl.indexIsChanging) {
          final idx = newCtrl.index;
          setState(() => _sportFilter = idx == 0 ? 'all' : cats[idx - 1].id);
        }
      });
      if (mounted) setState(() => _tabController = newCtrl);
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _events = [];
        _sports = [];
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List<_LiveEvent> get _filtered => _events.where((e) {
        if (_sportFilter != 'all' && e.category != _sportFilter) return false;
        if (_liveOnly && !e.isLive && !e.alwaysOn) return false;
        return true;
      }).toList();

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: AppTheme.backgroundDecoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            _buildProviderBar(),
            if (_tabController != null && _sports.isNotEmpty) _buildSportTabs(),
            const SizedBox(height: 4),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 12),
      child: Row(
        children: [
          const Icon(Icons.sports_soccer_rounded, color: AppTheme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Text(
            'Live Matches',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _buildProviderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in _DataProvider.values) ...[
              _ModeChip(
                label: p.chipLabel,
                active: _provider == p,
                onTap: () {
                  if (_provider == p) return;
                  setState(() => _provider = p);
                  _load();
                },
              ),
              const SizedBox(width: 8),
            ],
            const SizedBox(width: 8),
            Container(width: 1, height: 24, color: Colors.white24),
            const SizedBox(width: 16),
            _ModeChip(
              label: '🔴 Live only',
              active: _liveOnly,
              onTap: () => setState(() => _liveOnly = !_liveOnly),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSportTabs() {
    final tabs = [
      const Tab(text: 'All'),
      ..._sports.map((s) => Tab(text: s.name)),
    ];
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      indicatorColor: AppTheme.primaryColor,
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white38,
      tabAlignment: TabAlignment.start,
      dividerColor: Colors.white12,
      tabs: tabs,
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 12),
              Text("Couldn't load ${_provider.label}",
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryColor),
              ),
            ],
          ),
        ),
      );
    }

    final events = _filtered;
    if (events.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_rounded, color: Colors.white24, size: 64),
            const SizedBox(height: 16),
            Text(
              _liveOnly ? 'Nothing live right now' : 'No streams available',
              style: const TextStyle(color: Colors.white38, fontSize: 16),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final crossCount = (constraints.maxWidth / 300).floor().clamp(1, 6);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossCount,
          mainAxisExtent: 200,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: events.length,
        itemBuilder: (context, i) => _LiveEventCard(
          event: events[i],
          onTap: () => _openEvent(events[i]),
        ),
      );
    });
  }

  void _openEvent(_LiveEvent e) {
    if (e.sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stream not yet available for this event')),
      );
      return;
    }
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _LivePlayerScreen(event: e, provider: _provider),
    ));
  }
}

// ─── Chips ────────────────────────────────────────────────────────────────────

class _ModeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ModeChip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppTheme.primaryColor : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: active ? AppTheme.primaryColor : Colors.white24, width: 1.5),
        ),
        child: Text(label,
            style: TextStyle(
                color: active ? Colors.white : Colors.white60,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
                fontSize: 13)),
      ),
    );
  }
}

class _TeamBadge extends StatelessWidget {
  final String? badge;
  final String name;
  const _TeamBadge({required this.badge, required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = Text(name.isNotEmpty ? name[0] : '?',
        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold));
    return Column(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: Colors.white12,
          child: badge != null && badge!.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: badge!,
                  width: 38, height: 38, fit: BoxFit.contain,
                  errorWidget: (_, _, _) => initial,
                )
              : initial,
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 70,
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 9.5)),
        ),
      ],
    );
  }
}

// ─── Event Card ───────────────────────────────────────────────────────────────

class _LiveEventCard extends StatefulWidget {
  final _LiveEvent event;
  final VoidCallback onTap;
  const _LiveEventCard({required this.event, required this.onTap});

  @override
  State<_LiveEventCard> createState() => _LiveEventCardState();
}

class _LiveEventCardState extends State<_LiveEventCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final playable = e.sources.isNotEmpty;
    final time = e.timeLabel;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _hovered ? Colors.white.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.06),
            border: Border.all(
              color: _hovered ? AppTheme.primaryColor.withValues(alpha: 0.6) : Colors.white12,
              width: 1.5,
            ),
            boxShadow: _hovered
                ? [BoxShadow(color: AppTheme.primaryColor.withValues(alpha: 0.25), blurRadius: 16, spreadRadius: 2)]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              children: [
                if (e.poster != null && e.poster!.isNotEmpty)
                  Positioned.fill(
                    child: CachedNetworkImage(
                      imageUrl: e.poster!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.black.withValues(alpha: 0.90),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 34, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (e.hasTeams) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _TeamBadge(badge: e.homeBadge, name: e.homeTeam!),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('VS',
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2)),
                            ),
                            _TeamBadge(badge: e.awayBadge, name: e.awayTeam!),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],
                      Text(
                        e.title,
                        maxLines: e.hasTeams ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      if (e.league.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(e.league,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54, fontSize: 10.5)),
                      ],
                    ],
                  ),
                ),
                if (time.isNotEmpty)
                  Positioned(
                    top: 10, right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: time.startsWith('🔴') ? Colors.red.shade700 : Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(time,
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ),
                Positioned(
                  top: 10, left: 10,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(e.category.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60, fontSize: 9, letterSpacing: 0.8)),
                  ),
                ),
                if (!playable)
                  Positioned(
                    bottom: 8, left: 0, right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('Not yet available',
                            style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                if (_hovered && playable)
                  Positioned.fill(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.85),
                            shape: BoxShape.circle),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── WebView Player ───────────────────────────────────────────────────────────

class _LivePlayerScreen extends StatefulWidget {
  final _LiveEvent event;
  final _DataProvider provider;
  const _LivePlayerScreen({required this.event, required this.provider});

  @override
  State<_LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<_LivePlayerScreen> {
  bool _loading = true;
  bool _isFullscreen = false;
  int _sourceIndex = 0;

  _StreamOption get _source => widget.event.sources[_sourceIndex];

  void _enterFullscreen() async {
    setState(() => _isFullscreen = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  }

  void _exitFullscreen() async {
    setState(() => _isFullscreen = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    super.dispose();
  }

  void _pickServer() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Choose a server',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text("If one doesn't play, try another.",
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.event.sources.length,
                  itemBuilder: (_, i) {
                    final s = widget.event.sources[i];
                    final selected = i == _sourceIndex;
                    return ListTile(
                      onTap: () {
                        Navigator.pop(ctx);
                        if (!selected) {
                          setState(() {
                            _sourceIndex = i;
                            _loading = true;
                          });
                        }
                      },
                      leading: Icon(
                        selected ? Icons.play_circle_fill_rounded : Icons.dns_rounded,
                        color: selected ? AppTheme.primaryColor : Colors.white38,
                      ),
                      title: Text(s.label,
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = _source.url;
    final color = widget.provider.color;
    final multi = widget.event.sources.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              title: Text(widget.event.title,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                if (multi)
                  TextButton.icon(
                    onPressed: _pickServer,
                    icon: const Icon(Icons.dns_rounded, size: 18, color: Colors.white70),
                    label: Text(_source.label,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 12, left: 4),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: color)),
                      child: Text(widget.provider.label,
                          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ],
            ),
      body: Stack(
        children: [
          InAppWebView(
            key: ValueKey(url),
            initialUrlRequest: URLRequest(
              url: WebUri(url),
              headers: {'Referer': '${Uri.parse(url).origin}/'},
            ),
            initialSettings: InAppWebViewSettings(
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              javaScriptEnabled: true,
              disableDefaultErrorPage: true,
              supportMultipleWindows: false,
              useShouldOverrideUrlLoading: true,
              userAgent: _userAgent,
            ),
            onLoadStart: (_, _) => setState(() => _loading = true),
            onLoadStop: (_, _) => setState(() => _loading = false),
            onEnterFullscreen: (_) => _enterFullscreen(),
            onExitFullscreen: (_) => _exitFullscreen(),
            // Pop-up / redirect ads: keep the top-level page on the player's
            // own site. Embedded iframes (the actual video) are left alone.
            shouldOverrideUrlLoading: (ctrl, action) async {
              if (action.isForMainFrame != true) {
                return NavigationActionPolicy.ALLOW;
              }
              final target = action.request.url?.host ?? '';
              final home = Uri.tryParse(url)?.host ?? '';
              if (home.isNotEmpty && target.isNotEmpty && target != home &&
                  !target.endsWith('.$home')) {
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),
          if (_loading)
            const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
          if (multi && !_isFullscreen)
            Positioned(
              right: 16, bottom: 16,
              child: FloatingActionButton.small(
                heroTag: null,
                tooltip: 'Switch server',
                backgroundColor: AppTheme.primaryColor,
                onPressed: _pickServer,
                child: const Icon(Icons.swap_horiz_rounded, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}
