// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Runs a workload with [CurlClient] and then checks the process for native
/// memory leaks with the macOS `leaks` tool.
///
/// `leaks` can't inspect processes with the hardened runtime, such as the
/// `dart` executable, so the workload must be compiled first. Run it from the
/// package directory:
///
/// ```shell
/// dart build cli --target tool/leak_check.dart -o build/leak_check
/// MallocStackLogging=1 build/leak_check/bundle/bin/leak_check [iterations]
/// ```
///
/// `MallocStackLogging=1` makes `leaks` report where leaked memory was
/// allocated.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:curl_http/curl_http.dart';
import 'package:curl_http/src/native.dart' as native;
import 'package:http/http.dart';
import 'package:http2/multiprotocol_server.dart';
import 'package:http2/transport.dart';

final _largeBody = Uint8List(4 << 20);

Future<void> main(List<String> arguments) async {
  final iterations = arguments.isEmpty ? 3 : int.parse(arguments.first);
  // Must be run from the package directory.
  final certificates = Directory.current.uri.resolve('test/certificates/');
  final caCertificate = File.fromUri(
    certificates.resolve('ca.pem'),
  ).readAsBytesSync();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(_handleHttp11);
  final tlsServer = await MultiProtocolHttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
    SecurityContext()
      ..useCertificateChain(certificates.resolve('server.pem').toFilePath())
      ..usePrivateKey(certificates.resolve('server_key.pem').toFilePath()),
  );
  tlsServer.startServing(_handleHttp11, _handleHttp2, onError: (_, _) {});

  final http = Uri.http('127.0.0.1:${server.port}');
  final https = Uri.https('127.0.0.1:${tlsServer.port}');

  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; ++i) {
    for (final version in [CurlHttpVersion.http11, CurlHttpVersion.http2]) {
      await _workload(
        () => CurlClient(
          proxy: '',
          httpVersion: version,
          trustedCertificates: caCertificate,
        ),
        http,
        https,
      );
    }
    stdout.writeln('Iteration ${i + 1}/$iterations done');
  }
  stdout.writeln('Workload took ${stopwatch.elapsed}');

  // `MultiProtocolHttpServer.close` may not complete if connections are still
  // open, and then the isolate would exit (with exit code 0) once nothing else
  // is pending, so don't wait for long.
  await Future.wait([
    server.close(force: true),
    tlsServer.close(force: true),
  ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);

  // Wait for the worker threads to release their clients. Unclosed clients
  // are only released once they are garbage collected.
  final live = <String, int>{};
  for (var attempt = 0; attempt < 100; ++attempt) {
    await _collectGarbage();
    live
      ..['clients'] = native.liveObjectCount(native.NativeObjectKind.clients)
      ..['requests'] = native.liveObjectCount(native.NativeObjectKind.requests)
      ..['commands'] = native.liveObjectCount(native.NativeObjectKind.commands)
      ..['threads'] = native.liveObjectCount(native.NativeObjectKind.threads);
    if (live.values.every((count) => count == 0)) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  stdout.writeln('Live native objects: $live');

  final result = await Process.run('leaks', ['$pid']);
  stdout
    ..write(result.stdout)
    ..write(result.stderr);
  final leaked = result.exitCode != 0 || live.values.any((count) => count != 0);
  stdout.writeln(leaked ? 'LEAKS FOUND' : 'NO LEAKS FOUND');
  // `exit` doesn't wait for buffered output to be written.
  await stdout.flush();
  exit(leaked ? 1 : 0);
}

/// Performs full garbage collections, by allocating memory until the
/// [reachabilityBarrier] shows that they happened.
Future<void> _collectGarbage() async {
  final barrier = reachabilityBarrier;
  final storage = <List<Object>>[];
  while (reachabilityBarrier < barrier + 2) {
    await Future<void>.delayed(Duration.zero);
    storage.add(List<Object>.generate(30000, (i) => Object()));
    if (storage.length > 100) storage.removeAt(0);
  }
}

/// Exercises successful, failed, aborted and cancelled requests.
Future<void> _workload(
  CurlClient Function() createClient,
  Uri http,
  Uri https,
) async {
  final client = createClient();
  for (final base in [http, https]) {
    Uri url(String path) => base.resolve(path);
    final scheme = base.scheme;
    await _step('$scheme GET /small', () => client.get(url('/small')));
    await _step('$scheme GET /large', () => client.get(url('/large')));
    await _step(
      '$scheme POST /echo small',
      () => client.post(url('/echo'), body: 'hello'),
    );
    await _step(
      '$scheme POST /echo large',
      () => client.post(url('/echo'), body: _largeBody),
    );
    await _step('$scheme PUT /echo streamed', () async {
      final streamed = StreamedRequest('PUT', url('/echo'));
      streamed.sink
        ..add([1, 2, 3])
        ..add(_largeBody);
      unawaited(streamed.sink.close());
      await (await client.send(streamed)).stream.drain<void>();
    });
    await _step('$scheme HEAD /small', () => client.head(url('/small')));
    await _step(
      '$scheme concurrent GETs',
      () =>
          Future.wait([for (var i = 0; i < 20; ++i) client.get(url('/small'))]),
    );
    await _step(
      '$scheme redirect loop',
      () => _ignoreErrors(client.get(url('/redirect-loop'))),
    );
    await _step(
      '$scheme invalid header',
      () => _ignoreErrors(client.get(url('/small'), headers: {'bad name': ''})),
    );
    await _step(
      '$scheme aborted before sending',
      () => _ignoreErrors(
        client.send(
          AbortableRequest('GET', url('/small'), abortTrigger: Future.value()),
        ),
      ),
    );
    await _step('$scheme aborted while receiving', () async {
      final abort = Completer<void>();
      final response = await client.send(
        AbortableRequest('GET', url('/infinite'), abortTrigger: abort.future),
      );
      final body = response.stream.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      abort.complete();
      await _ignoreErrors(body);
    });
    await _step('$scheme cancelled response stream', () async {
      final response = await client.send(Request('GET', url('/infinite')));
      await response.stream.first;
    });
    await _step('$scheme failing request body', () async {
      final failing = StreamedRequest('POST', url('/small'));
      failing.sink
        ..add(_largeBody)
        ..addError(StateError('failed'));
      unawaited(failing.sink.close());
      await _ignoreErrors(client.send(failing));
    });
  }

  await _step('untrusted certificate and connection refused', () async {
    final untrusted = CurlClient(proxy: '');
    await _ignoreErrors(untrusted.get(https.resolve('/small')));
    await _ignoreErrors(untrusted.get(Uri.http('127.0.0.1:1')));
    untrusted.close();
  });

  await _step('closed with requests in progress', () async {
    final closing = createClient();
    final inProgress = await closing.send(
      Request('GET', http.resolve('/large')),
    );
    unawaited(_ignoreErrors(closing.get(https.resolve('/delay'))));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    closing.close();
    await _ignoreErrors(inProgress.stream.drain<void>());
  });

  // Not closed, so released by its finalizer.
  await _step('not closed', () => createClient().get(https.resolve('/small')));

  client.close();
}

/// Runs a step of the workload, failing if it takes too long.
Future<void> _step(String name, Future<void> Function() step) async {
  if (_verbose) stderr.writeln('  $name');
  await step().timeout(
    const Duration(seconds: 20),
    onTimeout: () => throw TimeoutException('Step "$name" timed out'),
  );
}

final _verbose = Platform.environment.containsKey('LEAK_CHECK_VERBOSE');

Future<void> _ignoreErrors(Future<Object?> future) =>
    future.then((_) {}, onError: (_) {});

Future<void> _handleHttp11(HttpRequest request) async {
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
        response.add(_largeBody);
      case '/delay':
        await Future<void>.delayed(const Duration(milliseconds: 200));
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
}

Future<void> _handleHttp2(ServerTransportStream stream) async {
  try {
    String? path;
    final body = BytesBuilder(copy: false);
    await for (final message in stream.incomingMessages) {
      if (message is HeadersStreamMessage) {
        for (final header in message.headers) {
          if (ascii.decode(header.name) == ':path') {
            path = ascii.decode(header.value);
          }
        }
      } else if (message is DataStreamMessage) {
        body.add(message.bytes);
      }
      if (message.endStream) break;
    }
    switch (path) {
      case '/small':
        stream
          ..sendHeaders([Header.ascii(':status', '200')])
          ..sendData(utf8.encode('hello'), endStream: true);
      case '/large':
        stream.sendHeaders([Header.ascii(':status', '200')]);
        _sendHttp2Body(stream, _largeBody);
      case '/echo':
        stream.sendHeaders([Header.ascii(':status', '200')]);
        _sendHttp2Body(stream, body.takeBytes());
      case '/delay':
        await Future<void>.delayed(const Duration(milliseconds: 200));
        stream.sendHeaders([Header.ascii(':status', '200')], endStream: true);
      case '/infinite':
        stream.sendHeaders([Header.ascii(':status', '200')]);
        final chunk = Uint8List(64 * 1024);
        for (var i = 0; i < 1000; ++i) {
          stream.sendData(chunk);
          await Future<void>.delayed(Duration.zero);
        }
        stream.sendData(const [], endStream: true);
      case '/redirect-loop':
        stream.sendHeaders([
          Header.ascii(':status', '302'),
          Header.ascii('location', '/redirect-loop'),
        ], endStream: true);
      default:
        stream.sendHeaders([Header.ascii(':status', '404')], endStream: true);
    }
  } on Object {
    // The client may reset the stream.
  }
}

/// Sends [bytes] and ends the stream.
///
/// `package:http2` versions without the fix for
/// https://github.com/dart-lang/http/issues/1998 stall if
/// `sendData(bytes, endStream: true)` sends more data than the peer's flow
/// control window allows, so the data is sent in chunks, followed by an empty
/// DATA frame that ends the stream.
void _sendHttp2Body(ServerTransportStream stream, Uint8List bytes) {
  const chunkSize = 64 * 1024;
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = i + chunkSize < bytes.length ? i + chunkSize : bytes.length;
    stream.sendData(Uint8List.sublistView(bytes, i, end));
  }
  stream.sendData(const [], endStream: true);
}
