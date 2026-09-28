import 'dart:io';

import 'package:http/http.dart' as http;

/// Helpers that stop the app's built-in proxies from being used to reach
/// devices on the user's own network (router admin pages, NAS, Jellyfin,
/// Nextcloud, etc.). Streaming sites loaded in the app's WebViews can make
/// requests to the local proxy, so the proxy must only ever fetch public
/// internet addresses on their behalf.

/// Thrown when a proxied request points at a local/private address.
class BlockedTargetException implements Exception {
  final Uri uri;
  BlockedTargetException(this.uri);

  @override
  String toString() =>
      'Blocked request to a local network address (${uri.host})';
}

bool _isPrivateV4(int a, int b) =>
    a == 0 || // "this" network
    a == 10 || // 10.0.0.0/8
    a == 127 || // loopback
    (a == 169 && b == 254) || // link-local
    (a == 172 && b >= 16 && b <= 31) || // 172.16.0.0/12
    (a == 192 && b == 168) || // 192.168.0.0/16
    (a == 100 && b >= 64 && b <= 127) || // 100.64.0.0/10 (CGNAT / Tailscale)
    a >= 224; // multicast / reserved

/// True for loopback, private LAN, link-local, CGNAT/Tailscale and other
/// non-public addresses.
bool isPrivateAddress(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4 && b.length == 4) {
    return _isPrivateV4(b[0], b[1]);
  }
  if (ip.type == InternetAddressType.IPv6 && b.length == 16) {
    if (b.every((x) => x == 0)) return true; // ::
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true; // fe80::/10
    final v4Mapped = b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (v4Mapped) return _isPrivateV4(b[12], b[13]);
  }
  return false;
}

/// Fast, synchronous check of a host *name* (no DNS lookup). True when the
/// host is an IP literal in a private range, `localhost`, a single-label
/// name, or uses a LAN-only suffix like `.local` / `.lan` / `.home.arpa`.
bool isLocalNetworkHost(String host) {
  final h = host.toLowerCase().trim();
  if (h.isEmpty) return false;
  final ip = InternetAddress.tryParse(h);
  if (ip != null) return isPrivateAddress(ip);
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  if (!h.contains('.')) return true; // e.g. "nas", "jellyfin"
  const lanSuffixes = [
    '.local',
    '.lan',
    '.home',
    '.home.arpa',
    '.internal',
    '.localdomain',
    '.intranet',
    '.corp',
  ];
  return lanSuffixes.any(h.endsWith);
}

final Map<String, (bool, DateTime)> _verdictCache = {};
const _verdictTtl = Duration(minutes: 5);

/// True if [uri] is http(s) and its host resolves only to public addresses.
Future<bool> isPublicTarget(Uri uri) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return false;

  final literal = InternetAddress.tryParse(host);
  if (literal != null) return !isPrivateAddress(literal);

  final cached = _verdictCache[host];
  if (cached != null && DateTime.now().difference(cached.$2) < _verdictTtl) {
    return cached.$1;
  }

  try {
    final addrs =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    final ok = addrs.isNotEmpty && !addrs.any(isPrivateAddress);
    _verdictCache[host] = (ok, DateTime.now());
    return ok;
  } catch (_) {
    // DNS failed: the real request will fail on its own with a clearer
    // error, so don't mask it (and don't cache).
    return true;
  }
}

/// Sends [method] to [uri] and follows redirects by hand, refusing any hop
/// (including the first) that points at a local/private address. Behaves
/// like a normal `client.send` otherwise.
Future<http.StreamedResponse> sendToPublicTarget(
  http.Client client,
  String method,
  Uri uri,
  Map<String, String> headers, {
  int maxRedirects = 5,
}) async {
  var current = uri;
  var currentMethod = method;
  for (var hop = 0; hop <= maxRedirects; hop++) {
    if (!await isPublicTarget(current)) {
      throw BlockedTargetException(current);
    }
    final req = http.Request(currentMethod, current)
      ..followRedirects = false
      ..headers.addAll(headers);
    final resp = await client.send(req);

    final location = resp.headers['location'];
    const redirectCodes = {301, 302, 303, 307, 308};
    if (!redirectCodes.contains(resp.statusCode) || location == null) {
      return resp;
    }
    final Uri next;
    try {
      next = current.resolve(location);
    } on FormatException {
      return resp; // malformed Location: hand back the 3xx as-is
    }
    // Discard the redirect body and move on to the next hop.
    await resp.stream.drain<void>();
    current = next;
    if (resp.statusCode == 303 && currentMethod != 'HEAD') {
      currentMethod = 'GET';
    }
  }
  throw http.ClientException('Too many redirects', uri);
}
