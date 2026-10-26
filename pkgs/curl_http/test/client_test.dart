// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests of [CurlClient] features that are not covered by the conformance
/// tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:curl_http/curl_http.dart';
import 'package:http/http.dart';
import 'package:http2/multiprotocol_server.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('curlVersion', () {
    test('describes the bundled libraries', () {
      expect(curlVersion, contains('libcurl/'));
      expect(curlVersion, contains('BoringSSL'));
      expect(curlVersion, contains('nghttp2/'));
    });
  });

  group('request headers', () {
    late HttpServer server;
    late Map<String, String?> received;

    setUp(() async {
      server = await startServer((request) async {
        received = {
          'user-agent': request.headers.value('user-agent'),
          'accept-encoding': request.headers.value('accept-encoding'),
        };
        await request.response.close();
      });
    });

    test('default User-Agent', () async {
      final client = testClient();
      await client.get(serverUrl(server));
      expect(received['user-agent'], startsWith('Dart/'));
      expect(received['user-agent'], endsWith('(package:curl_http)'));
    });

    test('custom User-Agent', () async {
      final client = testClient(userAgent: 'test-agent/1.0');
      await client.get(serverUrl(server));
      expect(received['user-agent'], 'test-agent/1.0');
    });

    test('User-Agent request header overrides userAgent', () async {
      final client = testClient(userAgent: 'test-agent/1.0');
      await client.get(serverUrl(server), headers: {'User-Agent': 'other'});
      expect(received['user-agent'], 'other');
    });

    test('default Accept-Encoding', () async {
      final client = testClient();
      await client.get(serverUrl(server));
      expect(received['accept-encoding'], 'gzip, deflate');
    });

    test('custom Accept-Encoding', () async {
      final client = testClient();
      await client.get(
        serverUrl(server),
        headers: {'Accept-Encoding': 'identity'},
      );
      expect(received['accept-encoding'], 'identity');
    });
  });

  group('response body decoding', () {
    final text = 'Hello World! ' * 1000;
    final encoded = utf8.encode(text);
    late HttpServer server;

    setUp(() async {
      server = await startServer((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/gzip':
            response.headers.set('content-encoding', 'gzip');
            response.add(gzip.encode(encoded));
          case '/zlib':
            response.headers.set('content-encoding', 'deflate');
            response.add(zlib.encode(encoded));
          case '/raw-deflate':
            response.headers.set('content-encoding', 'deflate');
            response.add(ZLibEncoder(raw: true).convert(encoded));
          case '/invalid-gzip':
            response.headers.set('content-encoding', 'gzip');
            response.add(utf8.encode('this is not gzip data'));
        }
        await response.close();
      });
    });

    for (final path in ['/gzip', '/zlib', '/raw-deflate']) {
      test(path, () async {
        final client = testClient();
        final response = await client.send(
          Request('GET', serverUrl(server, path)),
        );
        expect(response.contentLength, isNull);
        expect(response.headers['content-encoding'], isNotNull);
        expect(await response.stream.bytesToString(), text);
      });
    }

    test('invalid data', () async {
      final client = testClient();
      final response = await client.send(
        Request('GET', serverUrl(server, '/invalid-gzip')),
      );
      expect(response.statusCode, 200);
      await expectLater(
        response.stream.toBytes(),
        throwsA(isA<ClientException>()),
      );
    });

    test('HEAD', () async {
      final client = testClient();
      final response = await client.head(serverUrl(server, '/gzip'));
      expect(response.statusCode, 200);
      expect(response.bodyBytes, isEmpty);
    });
  });

  group('streaming', () {
    test('headers are received before the body', () async {
      final sendBody = Completer<void>();
      addTearDown(() {
        if (!sendBody.isCompleted) sendBody.complete();
      });
      // dart:io doesn't send the headers of a response before its body, so
      // a raw socket is used.
      final server = await startSocketServer((socket) async {
        socket.write(
          'HTTP/1.1 200 OK\r\nX-Test: value\r\nContent-Length: 4\r\n\r\n',
        );
        await sendBody.future;
        socket.write('body');
      });
      final client = testClient();
      final response = await client.send(
        Request('GET', Uri.http('127.0.0.1:${server.port}')),
      );
      expect(response.headers['x-test'], 'value');
      sendBody.complete();
      expect(await response.stream.bytesToString(), 'body');
    });

    test('download flow control', () async {
      const total = 64 * 1024 * 1024;
      var produced = 0;
      final server = await startServer((request) async {
        Stream<List<int>> generate() async* {
          final chunk = Uint8List(64 * 1024);
          while (produced < total) {
            produced += chunk.length;
            yield chunk;
          }
        }

        try {
          await request.response.addStream(generate());
          await request.response.close();
        } on Object {
          // The client may disconnect.
        }
      });
      final client = testClient();
      final response = await client.send(Request('GET', serverUrl(server)));

      var received = 0;
      final firstData = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen((data) {
        received += data.length;
        if (!firstData.isCompleted) {
          firstData.complete();
          subscription.pause();
        }
      });
      await firstData.future;
      await Future<void>.delayed(const Duration(seconds: 2));
      // The server can't produce much more than what fits into the socket
      // buffers and the client's receive window.
      expect(produced, lessThan(32 * 1024 * 1024));

      final done = subscription.asFuture<void>();
      subscription.resume();
      await done;
      expect(received, total);
    });

    test('upload flow control', () async {
      const total = 64 * 1024 * 1024;
      final firstData = Completer<void>();
      final resumeServer = Completer<void>();
      addTearDown(() {
        if (!resumeServer.isCompleted) resumeServer.complete();
      });
      final server = await startServer((request) async {
        var received = 0;
        final subscription = request.listen(null);
        subscription.onData((data) {
          received += data.length;
          if (!firstData.isCompleted) {
            firstData.complete();
            subscription.pause(resumeServer.future);
          }
        });
        await subscription.asFuture<void>();
        request.response.write('$received');
        await request.response.close();
      });

      var produced = 0;
      Stream<List<int>> generate() async* {
        final chunk = Uint8List(64 * 1024);
        while (produced < total) {
          produced += chunk.length;
          yield chunk;
        }
      }

      final client = testClient();
      final responseFuture = client.send(
        StreamRequest('POST', serverUrl(server), generate()),
      );
      await firstData.future;
      await Future<void>.delayed(const Duration(seconds: 2));
      // The body stream is paused once the socket buffers and the client's
      // send window are full.
      expect(produced, lessThan(32 * 1024 * 1024));

      resumeServer.complete();
      final response = await responseFuture;
      expect(await response.stream.bytesToString(), '$total');
    });

    test('large download', () async {
      final data = patternBytes(16 * 1024 * 1024);
      final server = await startServer((request) async {
        request.response.contentLength = data.length;
        request.response.add(data);
        await request.response.close();
      });
      final client = testClient();
      final response = await client.get(serverUrl(server));
      expect(response.contentLength, data.length);
      expectBytesEqual(response.bodyBytes, data);
    });

    test('large upload', () async {
      final data = patternBytes(16 * 1024 * 1024);
      final server = await startServer((request) async {
        final body = await request.fold(
          BytesBuilder(copy: false),
          (builder, data) => builder..add(data),
        );
        request.response.add(body.takeBytes());
        await request.response.close();
      });
      final client = testClient();
      final response = await client.post(serverUrl(server), body: data);
      expectBytesEqual(response.bodyBytes, data);
    });
  });

  group('connections', () {
    late HttpServer server;
    late List<int> clientPorts;

    setUp(() async {
      clientPorts = [];
      server = await startServer((request) async {
        clientPorts.add(request.connectionInfo!.remotePort);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.write(request.uri.path);
        await request.response.close();
      });
    });

    test('are reused', () async {
      final client = testClient();
      for (var i = 0; i < 5; ++i) {
        await client.get(serverUrl(server));
      }
      expect(clientPorts.toSet(), hasLength(1));
    });

    test('are not reused if persistentConnection is false', () async {
      final client = testClient();
      for (var i = 0; i < 5; ++i) {
        final request = Request('GET', serverUrl(server))
          ..persistentConnection = false;
        final response = await client.send(request);
        await response.stream.drain<void>();
      }
      expect(clientPorts.toSet(), hasLength(5));
    });

    test('maxConnectionsPerHost', () async {
      final client = testClient(maxConnectionsPerHost: 2);
      await Future.wait([
        for (var i = 0; i < 10; ++i) client.get(serverUrl(server, '/$i')),
      ]);
      expect(clientPorts, hasLength(10));
      expect(clientPorts.toSet().length, lessThanOrEqualTo(2));
    });

    test('many concurrent requests', () async {
      // Each request uses a new connection, so stay below the listen backlog
      // of the server (128 on macOS); otherwise some connection attempts
      // time out.
      final client = testClient();
      final responses = await Future.wait([
        for (var i = 0; i < 100; ++i) client.get(serverUrl(server, '/$i')),
      ]);
      for (var i = 0; i < responses.length; ++i) {
        expect(responses[i].body, '/$i');
      }
    });

    test('many concurrent requests with a connection limit', () async {
      final client = testClient(maxConnectionsPerHost: 16);
      final responses = await Future.wait([
        for (var i = 0; i < 400; ++i) client.get(serverUrl(server, '/$i')),
      ]);
      for (var i = 0; i < responses.length; ++i) {
        expect(responses[i].body, '/$i');
      }
      expect(clientPorts.toSet().length, lessThanOrEqualTo(16));
    });

    test('many sequential requests', () async {
      final client = testClient();
      final fastServer = await startServer((request) async {
        await request.response.close();
      });
      for (var i = 0; i < 1000; ++i) {
        final response = await client.get(serverUrl(fastServer));
        expect(response.statusCode, 200);
      }
    });
  });

  group('errors', () {
    test('connection refused', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final client = testClient();
      await expectLater(
        client.get(Uri.http('127.0.0.1:$port')),
        throwsA(isCurlClientException(7)),
      );
    });

    test('connection timeout', () async {
      // A server that accepts connections but never completes the TLS
      // handshake.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen(sockets.add);
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      final client = testClient(
        connectionTimeout: const Duration(milliseconds: 500),
      );
      final stopwatch = Stopwatch()..start();
      await expectLater(
        client.get(Uri.https('127.0.0.1:${server.port}')),
        throwsA(isCurlClientException(28)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('connection closed while receiving the body', () async {
      final server = await startRawServer(
        'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789',
      );
      final client = testClient();
      final response = await client.send(
        Request('GET', Uri.http('127.0.0.1:${server.port}')),
      );
      expect(response.statusCode, 200);
      await expectLater(
        response.stream.toBytes(),
        throwsA(isCurlClientException(18)),
      );
    });

    test('no response', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        socket.listen((_) => socket.destroy(), onError: (_) {});
      });
      addTearDown(server.close);
      final client = testClient();
      await expectLater(
        client.get(Uri.http('127.0.0.1:${server.port}')),
        throwsA(isA<CurlClientException>()),
      );
    });

    test('invalid header name', () async {
      final client = testClient();
      await expectLater(
        client.get(Uri.http('127.0.0.1:1'), headers: {'invalid name': 'value'}),
        throwsA(isA<ClientException>()),
      );
    });

    test('invalid header value', () async {
      final client = testClient();
      await expectLater(
        client.get(
          Uri.http('127.0.0.1:1'),
          headers: {'name': 'line1\r\nline2'},
        ),
        throwsA(isA<ClientException>()),
      );
    });

    test('unsupported scheme', () async {
      final client = testClient();
      await expectLater(
        client.get(Uri.parse('ftp://127.0.0.1/')),
        throwsA(isA<ClientException>()),
      );
    });

    test('HTTP/3 is not supported', () async {
      final client = testClient(httpVersion: CurlHttpVersion.http3Only);
      await expectLater(
        client.get(Uri.https('127.0.0.1:1')),
        throwsA(isA<CurlClientException>()),
      );
    });
  });

  group('close', () {
    late HttpServer server;
    late Completer<void> respond;

    setUp(() async {
      respond = Completer<void>();
      addTearDown(() {
        if (!respond.isCompleted) respond.complete();
      });
      server = await startServer((request) async {
        try {
          if (request.uri.path == '/body') {
            request.response.write('start');
            await request.response.flush();
          }
          await respond.future;
          await request.response.close();
        } on Object {
          // The client may disconnect.
        }
      });
    });

    test('while waiting for the response', () async {
      final client = CurlClient(proxy: '');
      final future = client.get(serverUrl(server));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      client.close();
      await expectLater(future, throwsA(isA<ClientException>()));
    });

    test('while receiving the body', () async {
      final client = CurlClient(proxy: '');
      final response = await client.send(
        Request('GET', serverUrl(server, '/body')),
      );
      final body = response.stream.toBytes();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      client.close();
      await expectLater(body, throwsA(isA<ClientException>()));
    });

    test('send after close', () async {
      final client = CurlClient(proxy: '')..close();
      await expectLater(
        client.get(serverUrl(server)),
        throwsA(isA<ClientException>()),
      );
    });
  });

  group('proxy', () {
    test('is used', () async {
      final requests = <String>[];
      final proxy = await startServer((request) async {
        requests.add('${request.method} ${request.headers.value('host')}');
        request.response.write('proxied');
        await request.response.close();
      });
      final client = CurlClient(proxy: 'http://127.0.0.1:${proxy.port}');
      addTearDown(client.close);
      final response = await client.get(Uri.http('example.invalid', '/path'));
      expect(response.body, 'proxied');
      expect(requests, ['GET example.invalid']);
    });

    test('noProxy', () async {
      final server = await startServer((request) async {
        request.response.write('direct');
        await request.response.close();
      });
      final client = CurlClient(
        proxy: 'http://127.0.0.1:1',
        noProxy: '127.0.0.1',
      );
      addTearDown(client.close);
      final response = await client.get(serverUrl(server));
      expect(response.body, 'direct');
    });
  });

  group('response framing', () {
    test('informational responses are ignored', () async {
      final server = await startRawServer(
        'HTTP/1.1 103 Early Hints\r\n'
        'Link: </style.css>; rel=preload\r\n'
        '\r\n'
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 5\r\n'
        'X-Final: yes\r\n'
        '\r\n'
        'hello',
      );
      final client = testClient();
      final response = await client.get(Uri.http('127.0.0.1:${server.port}'));
      expect(response.statusCode, 200);
      expect(response.body, 'hello');
      expect(response.headers['x-final'], 'yes');
      expect(response.headers, isNot(contains('link')));
    });

    test('trailers are ignored', () async {
      final server = await startRawServer(
        'HTTP/1.1 200 OK\r\n'
        'Transfer-Encoding: chunked\r\n'
        'Trailer: X-Trailer\r\n'
        '\r\n'
        '5\r\nhello\r\n'
        '0\r\nX-Trailer: value\r\n\r\n',
      );
      final client = testClient();
      final response = await client.get(Uri.http('127.0.0.1:${server.port}'));
      expect(response.body, 'hello');
      expect(response.headers, isNot(contains('x-trailer')));
    });
  });

  group('redirects', () {
    late HttpServer server;

    setUp(() async {
      server = await startServer((request) async {
        final body = await request.fold(
          BytesBuilder(copy: false),
          (builder, data) => builder..add(data),
        );
        final response = request.response;
        switch (request.uri.path) {
          case '/307':
            response
              ..statusCode = 307
              ..headers.set('location', '/echo');
          case '/303':
            response
              ..statusCode = 303
              ..headers.set('location', '/echo');
          case '/echo':
            response.write('${request.method} ${body.length}');
        }
        await response.close();
      });
    });

    test('307 resends the body', () async {
      final client = testClient();
      final response = await client.post(
        serverUrl(server, '/307'),
        body: 'hello',
      );
      expect(response.body, 'POST 5');
    });

    test('307 resends a streamed body', () async {
      final client = testClient();
      final request = StreamedRequest('PUT', serverUrl(server, '/307'));
      request.sink
        ..add(utf8.encode('hello '))
        ..add(utf8.encode('world'));
      unawaited(request.sink.close());
      final response = await client.send(request);
      expect(await response.stream.bytesToString(), 'PUT 11');
    });

    test('307 with a body that is too large to resend', () async {
      final client = testClient();
      await expectLater(
        client.post(serverUrl(server, '/307'), body: Uint8List(2 << 20)),
        throwsA(isCurlClientException(65)),
      );
    });

    test('303 switches to GET', () async {
      final client = testClient();
      final response = await client.post(
        serverUrl(server, '/303'),
        body: 'hello',
      );
      expect(response.body, 'GET 0');
    });
  });

  group('TLS', () {
    late MultiProtocolHttpServer server;
    late List<String> protocols;

    setUp(() async {
      protocols = [];
      server =
          await MultiProtocolHttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
              serverSecurityContext(),
            )
            ..startServing(
              (request) {
                protocols.add('http/1.1');
                request.response.write('hello');
                request.response.close();
              },
              (stream) {
                protocols.add('h2');
                stream.incomingMessages.listen((_) {}, onError: (_) {});
                stream
                  ..sendHeaders([Header.ascii(':status', '200')])
                  ..sendData(utf8.encode('hello'), endStream: true);
              },
              onError: (_, _) {},
            );
      addTearDown(() => server.close(force: true));
    });

    Uri url() => Uri.https('127.0.0.1:${server.port}', '/');

    test('trusted certificates', () async {
      final client = testClient(trustedCertificates: caCertificate);
      final response = await client.get(url());
      expect(response.body, 'hello');
    });

    test('untrusted certificate', () async {
      final client = testClient();
      await expectLater(client.get(url()), throwsA(isCurlClientException(60)));
    });

    test('verifyCertificates: false', () async {
      final client = testClient(verifyCertificates: false);
      final response = await client.get(url());
      expect(response.body, 'hello');
    });

    test('HTTP/2 is used by default', () async {
      final client = testClient(trustedCertificates: caCertificate);
      final response = await client.get(url());
      expect(response.statusCode, 200);
      expect(response.reasonPhrase, isNull);
      expect(protocols, ['h2']);
    });

    test('HTTP/1.1 can be forced', () async {
      final client = testClient(
        trustedCertificates: caCertificate,
        httpVersion: CurlHttpVersion.http11,
      );
      final response = await client.get(url());
      expect(response.statusCode, 200);
      expect(response.reasonPhrase, 'OK');
      expect(protocols, ['http/1.1']);
    });
  });

  group('TLS with a name-constrained certificate authority', () {
    // BoringSSL doesn't support name constraints for IP addresses, so on
    // Apple platforms these certificates are verified with the Security
    // framework. The certificates are generated by the test because the
    // Security framework rejects server certificates that are valid for more
    // than 825 days.
    late Directory directory;
    late HttpServer server;

    Future<void> openssl(List<String> arguments) async {
      final result = await Process.run(
        'openssl',
        arguments,
        workingDirectory: directory.path,
      );
      if (result.exitCode != 0) {
        fail('openssl ${arguments.join(' ')} failed: ${result.stderr}');
      }
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('curl_http_test');
      addTearDown(() => directory.delete(recursive: true));
      File('${directory.path}/openssl.cnf').writeAsStringSync('''
[req]
distinguished_name = dn
prompt = no
[dn]
CN = curl_http test CA
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
nameConstraints = critical,permitted;IP:127.0.0.0/255.0.0.0,permitted;DNS:localhost
[server]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
''');
      await openssl([
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', //
        '-keyout', 'ca_key.pem', '-out', 'ca.pem', '-days', '2',
        '-config', 'openssl.cnf', '-extensions', 'ca',
      ]);
      await openssl([
        'req', '-newkey', 'rsa:2048', '-nodes', '-sha256', //
        '-keyout', 'server_key.pem', '-out', 'server.csr',
        '-config', 'openssl.cnf', '-subj', '/CN=localhost',
      ]);
      await openssl([
        'x509', '-req', '-sha256', '-in', 'server.csr', //
        '-CA', 'ca.pem', '-CAkey', 'ca_key.pem', '-CAcreateserial',
        '-out', 'server.pem', '-days', '2',
        '-extfile', 'openssl.cnf', '-extensions', 'server',
      ]);
      server =
          await HttpServer.bindSecure(
              InternetAddress.loopbackIPv4,
              0,
              SecurityContext()
                ..useCertificateChain('${directory.path}/server.pem')
                ..usePrivateKey('${directory.path}/server_key.pem'),
            )
            ..listen((request) {
              request.response.write('constrained');
              request.response.close();
            });
      addTearDown(() => server.close(force: true));
    });

    for (final version in [CurlHttpVersion.http11, CurlHttpVersion.http2]) {
      test('$version', () async {
        final client = testClient(
          httpVersion: version,
          trustedCertificates: File(
            '${directory.path}/ca.pem',
          ).readAsBytesSync(),
        );
        final response = await client.get(
          Uri.https('127.0.0.1:${server.port}', '/'),
        );
        expect(response.body, 'constrained');
      });
    }

    test('untrusted', () async {
      // The certificate authority is not trusted.
      final client = testClient(trustedCertificates: caCertificate);
      await expectLater(
        client.get(Uri.https('127.0.0.1:${server.port}', '/')),
        throwsA(isCurlClientException(60)),
      );
    });
  }, testOn: 'mac-os');

  group('HTTP/2', () {
    test('requests are multiplexed over one connection', () async {
      final server = await Http2TestServer.start((request, stream) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        stream
          ..sendHeaders([Header.ascii(':status', '200')])
          ..sendData(utf8.encode(request.headers[':path']!), endStream: true);
      });
      final client = testClient(trustedCertificates: caCertificate);
      final responses = await Future.wait([
        for (var i = 0; i < 50; ++i) client.get(server.url('/$i')),
      ]);
      for (var i = 0; i < responses.length; ++i) {
        expect(responses[i].body, '/$i');
      }
      expect(server.connectionCount, 1);
    });

    test('prior knowledge', () async {
      final server = await Http2TestServer.start((request, stream) async {
        stream
          ..sendHeaders([Header.ascii(':status', '200')])
          ..sendData(utf8.encode('h2c'), endStream: true);
      }, secure: false);
      final client = testClient(
        httpVersion: CurlHttpVersion.http2PriorKnowledge,
      );
      final response = await client.get(server.url('/'));
      expect(response.body, 'h2c');
    });

    test('large download', () async {
      final data = patternBytes(16 * 1024 * 1024);
      final server = await Http2TestServer.start((request, stream) async {
        stream.sendHeaders([
          Header.ascii(':status', '200'),
          Header.ascii('content-length', '${data.length}'),
        ]);
        sendHttp2Body(stream, data);
      });
      final client = testClient(trustedCertificates: caCertificate);
      final response = await client.get(server.url('/'));
      expectBytesEqual(response.bodyBytes, data);
    });

    test('large upload', () async {
      final data = patternBytes(8 * 1024 * 1024);
      final server = await Http2TestServer.start((request, stream) async {
        final body = await request.body.fold(
          BytesBuilder(copy: false),
          (builder, data) => builder..add(data),
        );
        stream.sendHeaders([Header.ascii(':status', '200')]);
        sendHttp2Body(stream, body.takeBytes());
      });
      final client = testClient(trustedCertificates: caCertificate);
      final response = await client.post(server.url('/'), body: data);
      expectBytesEqual(response.bodyBytes, data);
    });
  });
}
