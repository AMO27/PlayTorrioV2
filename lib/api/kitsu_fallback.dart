import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Backup anime catalogue (Kitsu) used while AniList is switched off.
///
/// Everything in the app is keyed by AniList IDs, so each Kitsu entry is only
/// returned when Kitsu knows its AniList ID (Kitsu lists it under `mappings`).
/// Results are shaped like AniList's `Media` JSON so `AnimeCard.fromJson`
/// can read them unchanged.
class KitsuFallback {
  KitsuFallback._();

  static const String _base = 'https://kitsu.io/api/edge';
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  static Future<Map<String, dynamic>> _get(String path, Map<String, String> q) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: q);
    final req = await _client.getUrl(uri);
    req.headers.set('Accept', 'application/vnd.api+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw Exception('Kitsu: HTTP ${res.statusCode}');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Sort keys use AniList's names so callers don't need to change.
  static String _sort(String anilistSort) {
    switch (anilistSort) {
      case 'POPULARITY_DESC':
        return 'popularityRank';
      case 'FAVOURITES_DESC':
        return '-favoritesCount';
      case 'SCORE_DESC':
        return '-averageRating';
      case 'END_DATE_DESC':
        return '-endDate';
      case 'UPDATED_AT_DESC':
        return '-updatedAt';
      case 'START_DATE_DESC':
        return '-startDate';
      default: // TRENDING_DESC, SEARCH_MATCH, anything else
        return 'popularityRank';
    }
  }

  static String? _status(String? anilistStatus) {
    switch (anilistStatus) {
      case 'RELEASING':
        return 'current';
      case 'FINISHED':
        return 'finished';
      case 'NOT_YET_RELEASED':
        return 'upcoming';
    }
    return null;
  }

  /// Lists / search / browse. [search] uses Kitsu's text search.
  static Future<List<Map<String, dynamic>>> list({
    String sort = 'POPULARITY_DESC',
    String? status,
    String? search,
    String? genre,
    int? year,
    String? season,
    String? format,
    bool adult = false,
    int page = 1,
    int perPage = 20,
  }) async {
    // Ask for extra rows because entries without an AniList mapping are dropped.
    final limit = perPage * 2 > 20 ? 20 : perPage * 2; // Kitsu caps pages at 20.
    final q = <String, String>{
      'page[limit]': '$limit',
      'page[offset]': '${(page - 1) * limit}',
      'include': 'mappings,categories',
      'fields[mappings]': 'externalSite,externalId',
      'fields[categories]': 'title',
    };
    if (search != null && search.trim().isNotEmpty) {
      q['filter[text]'] = search.trim();
    } else {
      q['sort'] = _sort(sort);
    }
    final st = _status(status);
    if (st != null) q['filter[status]'] = st;
    if (genre != null && genre.isNotEmpty) {
      q['filter[categories]'] = genre.toLowerCase().replaceAll(' ', '-');
    }
    if (year != null) q['filter[seasonYear]'] = '$year';
    if (season != null && season.isNotEmpty) q['filter[season]'] = season.toLowerCase();
    if (format != null && format.isNotEmpty) {
      q['filter[subtype]'] = format == 'MOVIE' ? 'movie' : format;
    }
    if (!adult) q['filter[ageRating]'] = 'G,PG,R';

    final json = await _get('/anime', q);
    return _convert(json).take(perPage).toList();
  }

  /// One title by its AniList ID, or null if Kitsu doesn't know it.
  static Future<Map<String, dynamic>?> byAnilistId(int anilistId) async {
    final map = await _get('/mappings', {
      'filter[externalSite]': 'anilist/anime',
      'filter[externalId]': '$anilistId',
      'include': 'item',
    });
    final included = (map['included'] as List?) ?? const [];
    String? kitsuId;
    for (final i in included) {
      if (i is Map && i['type'] == 'anime') {
        kitsuId = i['id']?.toString();
        break;
      }
    }
    if (kitsuId == null) return null;
    final json = await _get('/anime/$kitsuId', {
      'include': 'mappings,categories',
      'fields[mappings]': 'externalSite,externalId',
      'fields[categories]': 'title',
    });
    final one = _convertOne(
      (json['data'] as Map).cast<String, dynamic>(),
      ((json['included'] as List?) ?? const []).whereType<Map>().toList(),
      forcedAnilistId: anilistId,
    );
    return one;
  }

  static List<Map<String, dynamic>> _convert(Map<String, dynamic> json) {
    final included = ((json['included'] as List?) ?? const []).whereType<Map>().toList();
    final out = <Map<String, dynamic>>[];
    for (final d in (json['data'] as List?) ?? const []) {
      if (d is! Map) continue;
      final one = _convertOne(d.cast<String, dynamic>(), included);
      if (one != null) out.add(one);
    }
    return out;
  }

  static Map<String, dynamic>? _convertOne(
    Map<String, dynamic> d,
    List<Map> included, {
    int? forcedAnilistId,
  }) {
    final attrs = (d['attributes'] as Map?)?.cast<String, dynamic>() ?? {};
    final rels = (d['relationships'] as Map?)?.cast<String, dynamic>() ?? {};

    Iterable<Map> relItems(String rel) {
      final ids = ((rels[rel]?['data'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => '${e['type']}:${e['id']}')
          .toSet();
      return included.where((i) => ids.contains('${i['type']}:${i['id']}'));
    }

    int? anilistId = forcedAnilistId;
    if (anilistId == null) {
      for (final m in relItems('mappings')) {
        final a = (m['attributes'] as Map?) ?? {};
        if (a['externalSite'] == 'anilist/anime') {
          anilistId = int.tryParse('${a['externalId']}');
          break;
        }
      }
    }
    if (anilistId == null) return null; // can't be streamed without it

    final titles = (attrs['titles'] as Map?)?.cast<String, dynamic>() ?? {};
    final canonical = (attrs['canonicalTitle'] ?? '').toString();
    final english = (titles['en'] ?? titles['en_us'] ?? canonical).toString();
    final romaji = (titles['en_jp'] ?? canonical).toString();
    final native = (titles['ja_jp'] ?? '').toString();

    final poster = (attrs['posterImage'] as Map?)?.cast<String, dynamic>() ?? {};
    final cover = (attrs['coverImage'] as Map?)?.cast<String, dynamic>() ?? {};

    int? ymd(String? s, int idx) {
      if (s == null || s.length < 10) return null;
      return int.tryParse(s.split('-')[idx]);
    }

    final start = attrs['startDate']?.toString();
    final end = attrs['endDate']?.toString();
    final startMonth = ymd(start, 1);
    String? season;
    if (startMonth != null) {
      season = startMonth <= 3
          ? 'WINTER'
          : startMonth <= 6
              ? 'SPRING'
              : startMonth <= 9
                  ? 'SUMMER'
                  : 'FALL';
    }

    String? status;
    switch (attrs['status']) {
      case 'current':
        status = 'RELEASING';
        break;
      case 'finished':
        status = 'FINISHED';
        break;
      case 'upcoming':
      case 'tba':
      case 'unreleased':
        status = 'NOT_YET_RELEASED';
        break;
    }

    String? format;
    switch ((attrs['subtype'] ?? '').toString().toLowerCase()) {
      case 'tv':
        format = 'TV';
        break;
      case 'movie':
        format = 'MOVIE';
        break;
      case 'ova':
        format = 'OVA';
        break;
      case 'ona':
        format = 'ONA';
        break;
      case 'special':
        format = 'SPECIAL';
        break;
      case 'music':
        format = 'MUSIC';
        break;
    }

    final rating = double.tryParse('${attrs['averageRating']}');
    final genres = relItems('categories')
        .map((c) => ((c['attributes'] as Map?)?['title'] ?? '').toString())
        .where((t) => t.isNotEmpty)
        .toList();

    final yt = attrs['youtubeVideoId']?.toString() ?? '';

    return {
      'id': anilistId,
      'title': {'english': english, 'romaji': romaji, 'native': native},
      'coverImage': {
        'large': poster['large'] ?? poster['original'],
        'extraLarge': poster['original'] ?? poster['large'],
        'color': null,
      },
      'bannerImage': cover['large'] ?? cover['original'],
      'format': format,
      'status': status,
      'episodes': attrs['episodeCount'],
      'duration': attrs['episodeLength'],
      'averageScore': rating?.round(),
      'popularity': attrs['userCount'],
      'description': attrs['synopsis'],
      'genres': genres,
      'seasonYear': ymd(start, 0),
      'season': season,
      'startDate': {'year': ymd(start, 0), 'month': ymd(start, 1), 'day': ymd(start, 2)},
      'endDate': {'year': ymd(end, 0), 'month': ymd(end, 1), 'day': ymd(end, 2)},
      'isAdult': attrs['nsfw'] == true,
      'studios': {'nodes': const []},
      'nextAiringEpisode': null,
      'trailer': yt.isEmpty ? null : {'id': yt, 'site': 'youtube', 'thumbnail': null},
      'streamingEpisodes': const [],
    };
  }

  static void log(String m) => debugPrint('[KitsuFallback] $m');
}
