import 'dart:io';

import 'package:dan_xi/repository/cookie/independent_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IndependentCookieJar.loadForRequest', () {
    test('sends a host-only cookie only to its exact host', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')..path = '/';

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      expect(
        await jar.loadForRequest(Uri.parse('https://example.com/')),
        hasLength(1),
      );
      expect(
        await jar.loadForRequest(Uri.parse('https://sub.example.com/')),
        isEmpty,
      );
    });

    test('sends a domain cookie to its domain and subdomains', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..domain = '.example.com'
        ..path = '/';

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      expect(
        await jar.loadForRequest(Uri.parse('https://example.com/')),
        hasLength(1),
      );
      expect(
        await jar.loadForRequest(Uri.parse('https://sub.example.com/')),
        hasLength(1),
      );
    });

    test('does not send a domain cookie to a suffix lookalike', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..domain = '.example.com'
        ..path = '/';

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('https://notexample.com/'),
      );

      expect(cookies, isEmpty);
    });

    test('rejects a domain cookie unrelated to the response host', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..domain = 'attacker.example'
        ..path = '/';

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('https://attacker.example/'),
      );

      expect(cookies, isEmpty);
    });

    test('does not apply suffix domain matching to IP addresses', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..domain = '0.0.1'
        ..path = '/';

      await jar.saveFromResponse(Uri.parse('https://127.0.0.1/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(Uri.parse('https://127.0.0.1/'));

      expect(cookies, isEmpty);
    });

    test('rejects a domain cookie for a single-label public suffix', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..domain = 'com'
        ..path = '/';

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('https://example.com/'),
      );

      expect(cookies, isEmpty);
    });

    test('sends a cookie to its exact path and child paths', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')..path = '/account';

      await jar.saveFromResponse(
        Uri.parse('https://example.com/account/login'),
        [cookie],
      );

      expect(
        await jar.loadForRequest(Uri.parse('https://example.com/account')),
        hasLength(1),
      );
      final matchingCookies = await jar.loadForRequest(
        Uri.parse('https://example.com/account/me'),
      );
      expect(matchingCookies, hasLength(1));
      expect(matchingCookies.single.path, '/account');
    });

    test('derives a missing cookie path from the response directory', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value');

      await jar.saveFromResponse(
        Uri.parse('https://example.com/account/login'),
        [cookie],
      );

      final matchingCookies = await jar.loadForRequest(
        Uri.parse('https://example.com/account/me'),
      );
      expect(matchingCookies, hasLength(1));
      expect(matchingCookies.single.path, '/account');
      expect(
        await jar.loadForRequest(Uri.parse('https://example.com/other')),
        isEmpty,
      );
    });

    test('restores the stored path on a legacy cookie without one', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')..path = '/account';

      await jar.saveFromResponse(
        Uri.parse('https://example.com/account/login'),
        [cookie],
      );
      final storedCookies = jar.hostCookies['example.com']!.remove('/account')!;
      jar.hostCookies['example.com']!['/account/login'] = storedCookies;
      cookie.path = null;

      final cookies = await jar.loadForRequest(
        Uri.parse('https://example.com/account/me'),
      );

      expect(cookies, hasLength(1));
      expect(cookies.single.path, '/account');
    });

    test(
      'replaces an invalid cookie path with the response directory',
      () async {
        final jar = IndependentCookieJar();
        final cookie = Cookie('session', 'value')..path = 'account';

        await jar.saveFromResponse(
          Uri.parse('https://example.com/account/login'),
          [cookie],
        );

        final cookies = await jar.loadForRequest(
          Uri.parse('https://example.com/account'),
        );

        expect(cookies, hasLength(1));
        expect(cookies.single.path, '/account');
      },
    );

    test(
      'does not send a cookie to a path with only a shared prefix',
      () async {
        final jar = IndependentCookieJar();
        final cookie = Cookie('session', 'value')..path = '/account';

        await jar.saveFromResponse(
          Uri.parse('https://example.com/account/login'),
          [cookie],
        );

        final cookies = await jar.loadForRequest(
          Uri.parse('https://example.com/accounting'),
        );

        expect(cookies, isEmpty);
      },
    );

    test(
      'sends same-name cookies for each matching path, longest first',
      () async {
        final jar = IndependentCookieJar();

        await jar.saveFromResponse(Uri.parse('https://example.com/'), [
          Cookie('session', 'root')..path = '/',
          Cookie('session', 'account')..path = '/account',
        ]);

        final cookies = await jar.loadForRequest(
          Uri.parse('https://example.com/account'),
        );

        expect(cookies.map((cookie) => cookie.value), ['account', 'root']);
      },
    );

    test('orders matching host and domain cookies by longest path', () async {
      final jar = IndependentCookieJar();

      await jar.saveFromResponse(Uri.parse('https://sub.example.com/'), [
        Cookie('session', 'host-root')..path = '/',
        Cookie('session', 'domain-account')
          ..domain = '.example.com'
          ..path = '/account',
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('https://sub.example.com/account'),
      );

      expect(cookies.map((cookie) => cookie.value), [
        'domain-account',
        'host-root',
      ]);
    });

    test('does not send a Secure cookie over HTTP', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..path = '/'
        ..secure = true;

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('http://example.com/'),
      );

      expect(cookies, isEmpty);
    });

    test('sends an unexpired Secure cookie over HTTPS', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..path = '/'
        ..secure = true;

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);

      final cookies = await jar.loadForRequest(
        Uri.parse('https://example.com/'),
      );

      expect(cookies, hasLength(1));
    });

    test('does not send a Secure cookie after it expires', () async {
      final jar = IndependentCookieJar();
      final cookie = Cookie('session', 'value')
        ..path = '/'
        ..secure = true
        ..expires = DateTime.now().add(const Duration(milliseconds: 100));

      await jar.saveFromResponse(Uri.parse('https://example.com/login'), [
        cookie,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final cookies = await jar.loadForRequest(
        Uri.parse('https://example.com/'),
      );

      expect(cookies, isEmpty);
    });
  });
}
