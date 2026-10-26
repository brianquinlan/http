// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Tests that [CurlClient] releases all of its native resources.
///
/// The native library counts the objects that it allocates (clients,
/// requests, queued commands, buffers and worker threads). These counts are
/// global to the process, so these tests must not run concurrently with other
/// tests that use [CurlClient] (see `dart_test.yaml`).
library;

import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:curl_http/curl_http.dart';
import 'package:curl_http/src/native.dart' as native;
import 'package:http/http.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

const _objectKinds = {
  'clients': native.NativeObjectKind.clients,
  'requests': native.NativeObjectKind.requests,
  'commands': native.NativeObjectKind.commands,
  'buffers': native.NativeObjectKind.buffers,
  'threads': native.NativeObjectKind.threads,
};

Map<String, int> _liveObjects() => {
  for (final MapEntry(:key, :value) in _objectKinds.entries)
    key: native.liveObjectCount(value),
};

/// Performs a full garbage collection, so that response body buffers owned by
/// Dart are freed and unreachable clients are finalized.
///
/// Allocates memory until the [reachabilityBarrier] shows that a full
/// garbage collection happened (as `package:leak_tracker` does).
Future<void> _collectGarbage() async {
  final barrier = reachabilityBarrier;
  final storage = <List<Object>>[];
  while (reachabilityBarrier < barrier + 2) {
    await Future<void>.delayed(Duration.zero);
    storage.add(List<Object>.generate(30000, (i) => Object()));
    if (storage.length > 100) storage.removeAt(0);
  }
}

/// Waits until all native objects are released.
///
/// Native objects are released asynchronously by the worker threads.
Future<void> _expectNoLiveObjects() async {
  final stopwatch = Stopwatch()..start();
  for (;;) {
    await _collectGarbage();
    final live = _liveObjects();
    if (live.values.every((count) => count == 0)) return;
    if (stopwatch.elapsed > const Duration(seconds: 15)) {
      fail('Native objects were not released: $live');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late HttpServer server;
  late Uri tlsUrl;
  final largeBody = Uint8List(4 << 20);

  Uri url(String path) => serverUrl(server, path);

  setUpAll(() async {
    server = await startServer((request) async {
      try {
        final response = request.response;
        if (request.uri.path == '/echo') {
          await response.addStream(request);
          await response.close();
          return;
        }
        await request.drain<void>();
        switch (request.uri.path) {
          case '/small':
            response.write('hello');
          case '/large':
            response.add(largeBody);
          case '/delay':
            await Future<void>.delayed(const Duration(milliseconds: 500));
          case '/infinite':
            // Stop when the client disconnects. `flush` may complete
            // immediately once the connection is closed, so also yield to
            // the event loop.
            var disconnected = false;
            unawaited(
              response.done.then(
                (_) => disconnected = true,
                onError: (_) => disconnected = true,
              ),
            );
            final chunk = Uint8List(64 * 1024);
            for (var i = 0; i < 16384 && !disconnected; ++i) {
              response.add(chunk);
              await response.flush();
              await Future<void>.delayed(Duration.zero);
            }
          case '/redirect-loop':
            response
              ..statusCode = 302
              ..headers.set('location', '/redirect-loop');
        }
        await response.close();
      } on Object {
        // The client may disconnect.
      }
    });
    final tlsServer = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverSecurityContext(),
    );
    tlsServer.listen((socket) => socket.destroy(), onError: (_) {});
    tlsUrl = Uri.https('127.0.0.1:${tlsServer.port}');
    addTearDown(tlsServer.close);
  });

  setUp(_expectNoLiveObjects);

  test('successful requests', () async {
    final client = CurlClient(proxy: '');
    // Closing it again is harmless; this releases it if the test fails.
    addTearDown(client.close);
    for (var i = 0; i < 5; ++i) {
      expect((await client.get(url('/small'))).body, 'hello');
      expect((await client.get(url('/large'))).bodyBytes, hasLength(4 << 20));
      expect((await client.post(url('/echo'), body: 'hi')).body, 'hi');
      expect(
        (await client.post(url('/echo'), body: largeBody)).bodyBytes,
        hasLength(4 << 20),
      );
      final streamed = StreamedRequest('PUT', url('/echo'));
      streamed.sink
        ..add([1, 2, 3])
        ..add(largeBody);
      unawaited(streamed.sink.close());
      final response = await client.send(streamed);
      expect(await response.stream.toBytes(), hasLength(3 + (4 << 20)));
      expect((await client.head(url('/large'))).bodyBytes, isEmpty);
    }
    await Future.wait([
      for (var i = 0; i < 50; ++i) client.get(url('/small')),
      for (var i = 0; i < 5; ++i) client.get(url('/large')),
    ]);
    client.close();
    await _expectNoLiveObjects();
  });

  test('failed requests', () async {
    final client = CurlClient(proxy: '');
    // Closing it again is harmless; this releases it if the test fails.
    addTearDown(client.close);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = socket.port;
    await socket.close();
    final partial = await startRawServer(
      'HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npartial',
    );

    for (var i = 0; i < 5; ++i) {
      await expectLater(
        client.get(Uri.http('127.0.0.1:$closedPort')),
        throwsA(isCurlClientException(7)),
      );
      await expectLater(
        client.get(url('/redirect-loop')),
        throwsA(isA<ClientException>()),
      );
      await expectLater(
        client.get(url('/small'), headers: {'bad header': ''}),
        throwsA(isA<ClientException>()),
      );
      await expectLater(client.get(tlsUrl), throwsA(isA<ClientException>()));
      await expectLater(
        client.get(Uri.http('127.0.0.1:${partial.port}')),
        throwsA(isCurlClientException(18)),
      );
      // The server reads the whole body before it responds, so the request
      // fails.
      final failing = StreamedRequest('POST', url('/small'));
      failing.sink
        ..add(largeBody)
        ..addError(StateError('body failed'));
      unawaited(failing.sink.close());
      await expectLater(client.send(failing), throwsA(isA<StateError>()));
    }
    client.close();
    await _expectNoLiveObjects();
  });

  test('aborted requests', () async {
    final client = CurlClient(proxy: '');
    // Closing it again is harmless; this releases it if the test fails.
    addTearDown(client.close);
    for (var i = 0; i < 5; ++i) {
      // Aborted before it is sent.
      await expectLater(
        client.send(
          AbortableRequest('GET', url('/small'), abortTrigger: Future.value()),
        ),
        throwsA(isA<RequestAbortedException>()),
      );

      // Aborted while receiving the response body.
      final abortResponse = Completer<void>();
      final response = await client.send(
        AbortableRequest(
          'GET',
          url('/infinite'),
          abortTrigger: abortResponse.future,
        ),
      );
      final body = response.stream.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      abortResponse.complete();
      await expectLater(body, throwsA(isA<RequestAbortedException>()));

      // Aborted while sending the request body. The server waits for the
      // whole body before it responds.
      final abortRequest = Completer<void>();
      final upload = AbortableStreamedRequest(
        'POST',
        url('/small'),
        abortTrigger: abortRequest.future,
      );
      upload.sink.add(largeBody);
      final responseFuture = client.send(upload);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      abortRequest.complete();
      await expectLater(
        responseFuture,
        throwsA(isA<RequestAbortedException>()),
      );
      unawaited(upload.sink.close());
    }
    client.close();
    await _expectNoLiveObjects();
  });

  test('cancelled response streams', () async {
    final client = CurlClient(proxy: '');
    // Closing it again is harmless; this releases it if the test fails.
    addTearDown(client.close);
    for (var i = 0; i < 5; ++i) {
      final infinite = await client.send(Request('GET', url('/infinite')));
      await infinite.stream.first;
      final large = await client.send(Request('GET', url('/large')));
      await large.stream.take(2).drain<void>();
    }
    client.close();
    await _expectNoLiveObjects();
  });

  test('closing a client with requests in progress', () async {
    final client = CurlClient(proxy: '');
    // Closing it again is harmless; this releases it if the test fails.
    addTearDown(client.close);
    final responses = <StreamedResponse>[];
    for (var i = 0; i < 5; ++i) {
      // Paused once the receive window is full.
      responses.add(await client.send(Request('GET', url('/infinite'))));
      // Waiting for the response.
      client.get(url('/delay')).ignore();
      // Sending the request body.
      final upload = StreamedRequest('POST', url('/echo'));
      upload.sink.add(largeBody);
      client.send(upload).ignore();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    client.close();
    for (final response in responses) {
      await expectLater(
        response.stream.drain<void>(),
        throwsA(isA<ClientException>()),
      );
    }
    await _expectNoLiveObjects();
  });

  test('clients that are not closed are finalized', () async {
    Future<void> useClient() async {
      final client = CurlClient(proxy: '');
      expect((await client.get(url('/large'))).bodyBytes, hasLength(4 << 20));
    }

    for (var i = 0; i < 5; ++i) {
      await useClient();
    }
    await _expectNoLiveObjects();
  });

  test('isolates that exit with requests in progress', () async {
    for (var i = 0; i < 10; ++i) {
      await _exitWithRequestsInProgress(url('/delay'), url('/infinite'));
    }
    await _expectNoLiveObjects();
  });

  test('isolates that exit before requests start', () async {
    for (var i = 0; i < 10; ++i) {
      await _exitBeforeRequestStarts(url('/small'));
    }
    await _expectNoLiveObjects();
  });
}

// The functions below run code in new isolates. They are top-level functions
// so that the closures that they send don't capture unsendable objects.

/// Runs an isolate that exits while a request is waiting for its response,
/// and while the transfer of another response is paused because the response
/// isn't listened to.
Future<void> _exitWithRequestsInProgress(Uri delayUrl, Uri infiniteUrl) =>
    Isolate.run(() async {
      final client = CurlClient(proxy: '');
      client.get(delayUrl).ignore();
      await client.send(Request('GET', infiniteUrl));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

/// Runs an isolate that exits before its request is started.
Future<void> _exitBeforeRequestStarts(Uri url) => Isolate.run(() {
  CurlClient(proxy: '').get(url).ignore();
});
