// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:async/async.dart';
import 'package:http/http.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'redirect_server_vm.dart'
    if (dart.library.js_interop) 'redirect_server_web.dart';

/// Tests that the [Client] correctly implements HTTP redirect logic.
///
/// If [canSendCookieHeaders] is `false` then tests that require that "cookie"
/// headers be sent by the client will not be run.
///
/// If [canSendProxyAuthorizationHeaders] is `false` then tests that require
/// that "proxy-authorization" headers be set by the client will not be run.
///
/// If [redirectAlwaysAllowed] is `true` then tests that require the [Client]
/// to limit redirects will be skipped.
void testRedirect(Client Function() clientFactory,
    {bool canSendCookieHeaders = true,
    bool canSendProxyAuthorizationHeaders = true,
    bool redirectAlwaysAllowed = false}) {
  group('redirects', () {
    // RFC 9110, 15.4 says:
    // Consider removing header fields that were not automatically generated
    // by the implementation...where there are security implications; this
    // includes but is not limited to Authorization and Cookie.
    //
    // RFC 6265, 8.5 says:
    // Cookies do not provide isolation by port. If a cookie is readable by a
    // service running on one port, the cookie is also readable by a service
    // running on another port of the same server.
    //
    // So the behavior that we test is:
    // - if a redirect changes hosts (e.g., localhost -> 127.0.0.1) then it
    //   MUST drop headers with security implications.
    // - if a redirect changes ports then it MUST drop headers with security
    //   implications, except for cookies which MAY be dropped
    // - headers with no security implications MUST NOT be dropped during
    //   redirect

    late Client client;
    late String localhost1;
    late String localhost2;
    late String loopback1;
    late String loopback2;
    late StreamChannel<Object?> httpServerChannel;
    late StreamQueue<Object?> httpServerQueue;

    setUp(() async {
      httpServerChannel = await startServer();
      httpServerQueue = StreamQueue(httpServerChannel.stream);
      final port1 = await httpServerQueue.nextAsInt;
      final port2 = await httpServerQueue.nextAsInt;
      localhost1 = 'localhost:$port1';
      localhost2 = 'localhost:$port2';
      loopback1 = '127.0.0.1:$port1';
      loopback2 = '127.0.0.1:$port2';
      client = clientFactory();
    });
    tearDown(() {
      client.close();
      httpServerChannel.sink.add(null);
    });

    test('no redirect', () async {
      final request = Request('GET', Uri.http(localhost1, '/'))
        ..followRedirects = false;
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 200);
      expect(response.isRedirect, false);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/'));
      }
    });

    test('disallow redirect', () async {
      final request = Request('GET', Uri.http(localhost1, '/1'))
        ..followRedirects = false;
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 302);
      expect(response.isRedirect, true);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/1'));
      }
    }, skip: redirectAlwaysAllowed ? 'redirects always allowed' : false);

    test('disallow redirect, 0 maxRedirects', () async {
      final request = Request('GET', Uri.http(localhost1, '/1'))
        ..followRedirects = false
        ..maxRedirects = 0;
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 302);
      expect(response.isRedirect, true);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/1'));
      }
    }, skip: redirectAlwaysAllowed ? 'redirects always allowed' : false);

    test('allow redirect', () async {
      final request = Request('GET', Uri.http(localhost1, '/1'))
        ..followRedirects = true;
      request.headers['hello'] = 'world';
      if (canSendCookieHeaders) {
        request.headers['cookie'] = 'foo=bar';
      }
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 200);
      expect(response.isRedirect, false);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/'));
      }
      final [server1, method1, body1, h1] =
          await httpServerQueue.next as List<Object?>;
      expect(server1, 'server1');
      expect(method1, 'GET');
      expect(body1, isEmpty);
      expect(h1, containsPair('host', [localhost1]));
      expect(h1, containsPair('hello', ['world']));
      if (canSendCookieHeaders) {
        expect(h1, containsPair('cookie', ['foo=bar']));
      }
      final [server2, method2, body2, h2] =
          await httpServerQueue.next as List<Object?>;
      expect(server2, 'server1');
      expect(method2, 'GET');
      expect(body2, isEmpty);
      expect(h2, containsPair('host', [localhost1]));
      expect(h2, containsPair('hello', ['world']));
      if (canSendCookieHeaders) {
        expect(h2, containsPair('cookie', ['foo=bar']));
      }
    });

    test('relative redirect', () async {
      final request = Request('GET', Uri.http(localhost1, '/relative'))
        ..followRedirects = true;
      request.headers['hello'] = 'world';
      if (canSendCookieHeaders) {
        request.headers['cookie'] = 'foo=bar';
      }
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 200);
      expect(response.isRedirect, false);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/'));
      }
      final [server1, method1, body1, h1] =
          await httpServerQueue.next as List<Object?>;
      expect(server1, 'server1');
      expect(method1, 'GET');
      expect(body1, isEmpty);
      expect(h1, containsPair('host', [localhost1]));
      expect(h1, containsPair('hello', ['world']));
      if (canSendCookieHeaders) {
        expect(h1, containsPair('cookie', ['foo=bar']));
      }
      final [server2, method2, body2, h2] =
          await httpServerQueue.next as List<Object?>;
      expect(server2, 'server1');
      expect(method2, 'GET');
      expect(body2, isEmpty);
      expect(h2, containsPair('host', [localhost1]));
      expect(h2, containsPair('hello', ['world']));
      if (canSendCookieHeaders) {
        expect(h2, containsPair('cookie', ['foo=bar']));
      }
    });

    test('allow redirect, 0 maxRedirects', () async {
      final request = Request('GET', Uri.http(localhost1, '/1'))
        ..followRedirects = true
        ..maxRedirects = 0;
      expect(
          client.send(request),
          throwsA(isA<ClientException>()
              .having((e) => e.message, 'message', 'Redirect limit exceeded')));
    }, skip: redirectAlwaysAllowed ? 'redirects always allowed' : false);

    test('exactly the right number of allowed redirects', () async {
      final request = Request('GET', Uri.http(localhost1, '/5'))
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 200);
      expect(response.isRedirect, false);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(localhost1, '/'));
      }
    }, skip: redirectAlwaysAllowed ? 'redirects always allowed' : false);

    test('too many redirects', () async {
      final request = Request('GET', Uri.http(localhost1, '/6'))
        ..followRedirects = true
        ..maxRedirects = 5;
      expect(
          client.send(request),
          throwsA(isA<ClientException>()
              .having((e) => e.message, 'message', 'Redirect limit exceeded')));
    }, skip: redirectAlwaysAllowed ? 'redirects always allowed' : false);

    test(
      'loop',
      () async {
        final request = Request('GET', Uri.http(localhost1, '/loop'))
          ..followRedirects = true
          ..maxRedirects = 5;
        expect(client.send(request), throwsA(isA<ClientException>()));
      },
    );

    for (final (authorization, cookie, proxyAuthorization) in [
      ('authorization', 'cookie', 'proxy-authorization'),
      ('Authorization', 'Cookie', 'Proxy-Authorization'),
      ('AUTHORIZATION', 'COOKIE', 'PROXY-AUTHORIZATION'),
    ]) {
      test(
          'cross port redirect '
          '($authorization, $cookie, $proxyAuthorization)', () async {
        final request = Request('GET', Uri.http(localhost1, '/cross-port'))
          ..followRedirects = true
          ..maxRedirects = 1;
        request.headers['hello'] = 'world';
        request.headers[authorization] = 'anything';
        if (canSendCookieHeaders) {
          request.headers[cookie] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers[proxyAuthorization] = 'anything';
        }

        final response = await client.send(request);
        await response.stream.drain<void>();
        expect(response.statusCode, 200);
        expect(response.isRedirect, false);
        if (response case BaseResponseWithUrl(url: final url)) {
          expect(url, Uri.http(localhost2, '/'));
        }

        final [server1, _, _, h1] = await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        final [server2, _, _, h2] = await httpServerQueue.next as List<Object?>;
        expect(server2, 'server2');
        expect(h2, containsPair('host', [localhost2]));
        expect(h2, containsPair('hello', ['world']));
        // Cookies may or may not be preserved.
        expect(h2, isNot(contains('authorization')));
        expect(h2, isNot(contains('proxy-authorization')));
      });

      test(
          'cross host redirect '
          '($authorization, $cookie, $proxyAuthorization)', () async {
        final request = Request('GET', Uri.http(localhost1, '/cross-host'))
          ..followRedirects = true
          ..maxRedirects = 1;
        request.headers['hello'] = 'world';
        request.headers[authorization] = 'anything';
        if (canSendCookieHeaders) {
          request.headers[cookie] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers[proxyAuthorization] = 'anything';
        }
        final response = await client.send(request);
        await response.stream.drain<void>();
        expect(response.statusCode, 200);
        expect(response.isRedirect, false);

        final [server1, _, _, h1] = await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        final [server2, _, _, h2] = await httpServerQueue.next as List<Object?>;
        expect(server2, 'server1');
        expect(h2, containsPair('host', [loopback1]));
        expect(h2, containsPair('hello', ['world']));
        expect(h2, isNot(contains('authorization')));
        expect(h2, isNot(contains('cookie')));
        expect(h2, isNot(contains('proxy-authorization')));
      });

      test(
          'cross host and back '
          '($authorization, $cookie, $proxyAuthorization)', () async {
        final request = Request('GET', Uri.http(localhost1, '/cross-ping'))
          ..followRedirects = true
          ..maxRedirects = 2;
        request.headers['hello'] = 'world';
        request.headers[authorization] = 'anything';
        if (canSendCookieHeaders) {
          request.headers[cookie] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers[proxyAuthorization] = 'anything';
        }
        final response = await client.send(request);
        await response.stream.drain<void>();
        expect(response.statusCode, 200);
        expect(response.isRedirect, false);
        if (response case BaseResponseWithUrl(url: final url)) {
          expect(url, Uri.http(localhost1, '/'));
        }

        final [server1, _, _, h1] = await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        final [server2, _, _, h2] = await httpServerQueue.next as List<Object?>;
        expect(server2, 'server2');
        expect(h2, containsPair('host', [loopback2]));
        expect(h2, containsPair('hello', ['world']));
        expect(h2, isNot(contains('authorization')));
        expect(h2, isNot(contains('cookie')));
        expect(h2, isNot(contains('proxy-authorization')));

        final [server3, _, _, h3] = await httpServerQueue.next as List<Object?>;
        expect(server3, 'server1');
        expect(h3, containsPair('host', [localhost1]));
        expect(h3, containsPair('hello', ['world']));
        expect(h3, isNot(contains('authorization')));
        expect(h3, isNot(contains('cookie')));
        expect(h3, isNot(contains('proxy-authorization')));
      });
    }

    test('scheme-relative cross host redirect', () async {
      final request = Request('GET', Uri.http(localhost1, '/scheme-relative'))
        ..followRedirects = true
        ..maxRedirects = 1;
      request.headers['hello'] = 'world';
      request.headers['authorization'] = 'anything';
      if (canSendCookieHeaders) {
        request.headers['cookie'] = 'foo=bar';
      }
      if (canSendProxyAuthorizationHeaders) {
        request.headers['proxy-authorization'] = 'anything';
      }
      final response = await client.send(request);
      await response.stream.drain<void>();
      expect(response.statusCode, 200);
      expect(response.isRedirect, false);
      if (response case BaseResponseWithUrl(url: final url)) {
        expect(url, Uri.http(loopback1, '/'));
      }

      final [server1, _, _, h1] = await httpServerQueue.next as List<Object?>;
      expect(server1, 'server1');
      expect(h1, containsPair('host', [localhost1]));
      expect(h1, containsPair('hello', ['world']));
      expect(h1, containsPair('authorization', ['anything']));
      if (canSendCookieHeaders) {
        expect(h1, containsPair('cookie', ['foo=bar']));
      }
      if (canSendProxyAuthorizationHeaders) {
        expect(h1, containsPair('proxy-authorization', ['anything']));
      }

      final [server2, _, _, h2] = await httpServerQueue.next as List<Object?>;
      expect(server2, 'server1');
      expect(h2, containsPair('host', [loopback1]));
      expect(h2, containsPair('hello', ['world']));
      expect(h2, isNot(contains('authorization')));
      expect(h2, isNot(contains('cookie')));
      expect(h2, isNot(contains('proxy-authorization')));
    });

    for (final code in [301, 302, 303]) {
      test('POST $code cross host redirect', () async {
        final request =
            Request('POST', Uri.http(localhost1, '/cross-host-$code'))
              ..body = 'Hello World!'
              ..followRedirects = true
              ..maxRedirects = 1;
        request.headers['hello'] = 'world';
        request.headers['authorization'] = 'anything';
        if (canSendCookieHeaders) {
          request.headers['cookie'] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers['proxy-authorization'] = 'anything';
        }

        final response = await client.send(request);
        await response.stream.drain<void>();

        final [server1, method1, body1, h1] =
            await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(method1, 'POST');
        expect(body1, 'Hello World!');
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        if (code == 303) {
          // RFC 9110, 15.4.4: 303 redirects POST to GET.
          expect(response.statusCode, 200);
        } else {
          // RFC 9110, 15.4.2-15.4.3:
          // The server SHOULD generate a Location header field in the response
          // containing a preferred URI reference for the new permanent URI.
          // The user agent MAY use the Location field value for automatic
          // redirection.
          // Note: For historical reasons, a user agent MAY change the request
          // method from POST to GET for the subsequent request.
          expect(response.statusCode, anyOf(200, code));
        }

        if (response.statusCode == 200) {
          expect(response.isRedirect, false);
          if (response case BaseResponseWithUrl(url: final url)) {
            expect(url, Uri.http(loopback2, '/'));
          }

          final [server2, method2, body2, h2] =
              await httpServerQueue.next as List<Object?>;
          expect(server2, 'server2');
          expect(method2, 'GET');
          expect(body2, isEmpty);
          expect(h2, containsPair('host', [loopback2]));
          expect(h2, containsPair('hello', ['world']));
          expect(h2, isNot(contains('authorization')));
          expect(h2, isNot(contains('cookie')));
          expect(h2, isNot(contains('proxy-authorization')));
        }
      });
    }

    for (final code in [307, 308]) {
      test('GET $code cross host redirect', () async {
        final request =
            Request('GET', Uri.http(localhost1, '/cross-host-$code'))
              ..followRedirects = true
              ..maxRedirects = 1;
        request.headers['hello'] = 'world';
        request.headers['authorization'] = 'anything';
        if (canSendCookieHeaders) {
          request.headers['cookie'] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers['proxy-authorization'] = 'anything';
        }

        final response = await client.send(request);
        await response.stream.drain<void>();
        expect(response.statusCode, 200);
        expect(response.isRedirect, false);
        if (response case BaseResponseWithUrl(url: final url)) {
          expect(url, Uri.http(loopback2, '/'));
        }

        final [server1, method1, body1, h1] =
            await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(method1, 'GET');
        expect(body1, isEmpty);
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        final [server2, method2, body2, h2] =
            await httpServerQueue.next as List<Object?>;
        expect(server2, 'server2');
        expect(method2, 'GET');
        expect(body2, isEmpty);
        expect(h2, containsPair('host', [loopback2]));
        expect(h2, containsPair('hello', ['world']));
        expect(h2, isNot(contains('authorization')));
        expect(h2, isNot(contains('cookie')));
        expect(h2, isNot(contains('proxy-authorization')));
      });

      test('POST $code cross host redirect', () async {
        final request =
            Request('POST', Uri.http(localhost1, '/cross-host-$code'))
              ..body = 'Hello World!'
              ..followRedirects = true
              ..maxRedirects = 1;
        request.headers['hello'] = 'world';
        request.headers['authorization'] = 'anything';
        if (canSendCookieHeaders) {
          request.headers['cookie'] = 'foo=bar';
        }
        if (canSendProxyAuthorizationHeaders) {
          request.headers['proxy-authorization'] = 'anything';
        }

        final response = await client.send(request);
        await response.stream.drain<void>();

        final [server1, method1, body1, h1] =
            await httpServerQueue.next as List<Object?>;
        expect(server1, 'server1');
        expect(method1, 'POST');
        expect(body1, 'Hello World!');
        expect(h1, containsPair('host', [localhost1]));
        expect(h1, containsPair('hello', ['world']));
        expect(h1, containsPair('authorization', ['anything']));
        if (canSendCookieHeaders) {
          expect(h1, containsPair('cookie', ['foo=bar']));
        }
        if (canSendProxyAuthorizationHeaders) {
          expect(h1, containsPair('proxy-authorization', ['anything']));
        }

        // RFC 9110, 15.4.8-15.4.9:
        // The user agent MAY use the Location field value for automatic
        // redirection, and MUST NOT change the request method if it performs an
        // automatic redirection to that URI.
        expect(response.statusCode, anyOf(200, code));

        if (response.statusCode == 200) {
          expect(response.isRedirect, false);
          if (response case BaseResponseWithUrl(url: final url)) {
            expect(url, Uri.http(loopback2, '/'));
          }

          final [server2, method2, body2, h2] =
              await httpServerQueue.next as List<Object?>;
          expect(server2, 'server2');
          expect(method2, 'POST');
          expect(body2, 'Hello World!');
          expect(h2, containsPair('host', [loopback2]));
          expect(h2, containsPair('hello', ['world']));
          expect(h2, isNot(contains('authorization')));
          expect(h2, isNot(contains('cookie')));
          expect(h2, isNot(contains('proxy-authorization')));
        }
      });
    }
  });
}
