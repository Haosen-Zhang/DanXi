/*
 *     Copyright (C) 2021  DanXi-Dev
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:io';

// ignore: implementation_imports
import 'package:cookie_jar/src/cookie_jar.dart';
// ignore: implementation_imports
import 'package:cookie_jar/src/serializable_cookie.dart';

/// A copy of [DefaultCookieJar], but with an independent cookie storage.
class IndependentCookieJar implements CookieJar {
  /// A array to save cookies.
  ///
  /// [domains[0]] save the cookies with "domain" attribute.
  /// These cookie usually need to be shared among multiple domains.
  ///
  /// [domains[1]] save the cookies without "domain" attribute.
  /// These cookies are private for each host name.
  ///
  final List<
    Map<
      String?, //domain or host
      Map<
        String, //path
        Map<
          String, //cookie name
          SerializableCookie //cookie
        >
      >
    >
  >
  _cookies = <Map<String?, Map<String, Map<String, SerializableCookie>>>>[
    <String?, Map<String, Map<String, SerializableCookie>>>{},
    <String?, Map<String, Map<String, SerializableCookie>>>{},
  ];

  IndependentCookieJar({this.ignoreExpires = false});

  Map<String?, Map<String, Map<String, SerializableCookie>>>
  get domainCookies => _cookies[0];

  Map<String?, Map<String, Map<String, SerializableCookie>>> get hostCookies =>
      _cookies[1];

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) async {
    final matches = <(SerializableCookie, int)>[];
    final urlPath = uri.path.isEmpty ? '/' : uri.path;
    // Load cookies without "domain" attribute, include port.
    final hostname = uri.host;
    for (final domain in hostCookies.keys) {
      if (hostname == domain) {
        final cookies = hostCookies[domain]!
            .cast<String, Map<String, dynamic>>();
        for (final path in cookies.keys) {
          final values = cookies[path]!;
          for (final key in values.keys) {
            final SerializableCookie cookie = values[key];
            final effectivePath = _storedPath(cookie.cookie, path);
            if (_pathMatches(urlPath, effectivePath) &&
                _check(uri.scheme, cookie)) {
              cookie.cookie.path = effectivePath;
              matches.add((cookie, matches.length));
            }
          }
        }
      }
    }
    // Load cookies with "domain" attribute, Ignore port.
    domainCookies.forEach((
      String? domain,
      Map<String, Map<String, SerializableCookie>> cookies,
    ) {
      if (_domainMatches(uri.host, domain!)) {
        cookies.forEach((String path, Map<String, SerializableCookie> values) {
          values.forEach((String key, SerializableCookie cookie) {
            final effectivePath = _storedPath(cookie.cookie, path);
            if (_pathMatches(urlPath, effectivePath) &&
                _check(uri.scheme, cookie)) {
              cookie.cookie.path = effectivePath;
              matches.add((cookie, matches.length));
            }
          });
        });
      }
    });
    matches.sort((a, b) {
      final pathComparison = (b.$1.cookie.path?.length ?? 0).compareTo(
        a.$1.cookie.path?.length ?? 0,
      );
      if (pathComparison != 0) return pathComparison;
      final creationComparison = a.$1.createTimeStamp.compareTo(
        b.$1.createTimeStamp,
      );
      return creationComparison != 0
          ? creationComparison
          : a.$2.compareTo(b.$2);
    });
    return matches.map((match) => match.$1.cookie).toList(growable: false);
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    for (final cookie in cookies) {
      var domain = cookie.domain;
      String path;
      var index = 0;
      // Save cookies with "domain" attribute
      if (domain != null) {
        if (domain.startsWith('.')) {
          domain = domain.substring(1);
        }
        domain = domain.toLowerCase();
        if (!_domainMatches(uri.host, domain)) continue;
        path = _effectivePath(cookie.path, uri.path);
      } else {
        index = 1;
        // Save cookies without "domain" attribute
        path = _effectivePath(cookie.path, uri.path);
        domain = uri.host;
      }
      cookie.path = path;
      var mapDomain =
          _cookies[index][domain] ?? <String, Map<String, dynamic>>{};
      mapDomain = mapDomain.cast<String, Map<String, dynamic>>();

      final map = mapDomain[path] ?? <String, dynamic>{};
      map[cookie.name] = SerializableCookie(cookie);
      if (_isExpired(map[cookie.name])) {
        map.remove(cookie.name);
      }
      mapDomain[path] = map.cast<String, SerializableCookie>();
      _cookies[index][domain] = mapDomain
          .cast<String, Map<String, SerializableCookie>>();
    }
  }

  /// Delete cookies for specified [uri].
  /// This API will delete all cookies for the `uri.host`, it will ignored the `uri.path`.
  ///
  /// [withDomainSharedCookie] `true` will delete the domain-shared cookies.
  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) async {
    final host = uri.host;
    hostCookies.remove(host);
    if (withDomainSharedCookie) {
      domainCookies.removeWhere(
        (String? domain, Map<String, Map<String, SerializableCookie>> v) =>
            _domainMatches(uri.host, domain!),
      );
    }
  }

  /// Delete all cookies in RAM
  @override
  Future<void> deleteAll() async {
    domainCookies.clear();
    hostCookies.clear();
  }

  bool _isExpired(SerializableCookie? cookie) {
    return ignoreExpires ? false : cookie!.isExpired();
  }

  static bool _domainMatches(String host, String domain) {
    final normalizedHost = host.toLowerCase();
    final normalizedDomain = domain.toLowerCase();
    if (normalizedHost == normalizedDomain) return true;
    if (_isIpAddress(normalizedHost)) return false;
    if (!normalizedDomain.contains('.')) return false;
    return normalizedHost.endsWith('.$normalizedDomain');
  }

  static bool _isIpAddress(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
    }
    return true;
  }

  static bool _pathMatches(String requestPath, String cookiePath) {
    if (requestPath == cookiePath) return true;
    if (!requestPath.startsWith(cookiePath)) return false;
    return cookiePath.endsWith('/') || requestPath[cookiePath.length] == '/';
  }

  static String _defaultPath(String requestPath) {
    if (!requestPath.startsWith('/')) return '/';
    final lastSlash = requestPath.lastIndexOf('/');
    return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash);
  }

  static String _effectivePath(String? cookiePath, String requestPath) {
    if (cookiePath == null ||
        cookiePath.isEmpty ||
        !cookiePath.startsWith('/')) {
      return _defaultPath(requestPath);
    }
    return cookiePath;
  }

  static String _storedPath(Cookie cookie, String storedPath) {
    final path = cookie.path;
    return path == null || path.isEmpty || !path.startsWith('/')
        ? _defaultPath(storedPath)
        : path;
  }

  bool _check(String scheme, SerializableCookie cookie) {
    if (_isExpired(cookie)) return false;
    return !cookie.cookie.secure || scheme == 'https';
  }

  factory IndependentCookieJar.createFrom(IndependentCookieJar otherJar) =>
      IndependentCookieJar()..cloneFrom(otherJar);

  /// Clone cookies from [otherJar] to this jar.
  ///
  /// The original cookies in this jar will be cleared before cloning.
  void cloneFrom(IndependentCookieJar otherJar) {
    _deepClone(otherJar.domainCookies, domainCookies);
    _deepClone(otherJar.hostCookies, hostCookies);
  }

  static void _deepClone(
    Map<String?, Map<String, Map<String, SerializableCookie>>> from,
    Map<String?, Map<String, Map<String, SerializableCookie>>> to,
  ) {
    to.clear();
    from.forEach((host, value) {
      to[host] = {};
      value.forEach((path, value) {
        to[host]![path] = {};
        value.forEach((cookieName, value) {
          to[host]![path]![cookieName] = SerializableCookie.fromJson(
            value.toJson(),
          );
        });
      });
    });
  }

  @override
  final bool ignoreExpires;

  void deleteCookiesByName(String name) {
    for (final domain in hostCookies.keys) {
      final cookies = hostCookies[domain]!;
      for (final path in cookies.keys) {
        final values = cookies[path]!;
        values.remove(name);
      }
    }
    for (final domain in domainCookies.keys) {
      final cookies = domainCookies[domain]!;
      for (final path in cookies.keys) {
        final values = cookies[path]!;
        values.remove(name);
      }
    }
  }
}
