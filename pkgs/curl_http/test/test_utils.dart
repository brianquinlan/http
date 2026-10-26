// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:curl_http/curl_http.dart';
import 'package:http/http.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

/// The certificate of the certificate authority that issued
/// `test/certificates/server.pem`.
final caCertificate = File('test/certificates/ca.pem').readAsBytesSync();

/// A [SecurityContext] for servers that use `test/certificates/server.pem`,
/// which is valid for "localhost", "127.0.0.1" and "::1".
SecurityContext serverSecurityContext() => SecurityContext()
  ..useCertificateChain('test/certificates/server.pem')
  ..usePrivateKey('test/certificates/server_key.pem');

/// Creates a [CurlClient] that doesn't use a proxy and is closed when the test
/// is complete.
CurlClient testClient({
  CurlHttpVersion? httpVersion,
  List<int>? trustedCertificates,
  bool verifyCertificates = true,
  String? userAgent,
  Duration? connectionTimeout,
  int? maxConnectionsPerHost,
}) {
  final client = CurlClient(
    httpVersion: httpVersion,
    trustedCertificates: trustedCertificates,
    verifyCertificates: verifyCertificates,
    userAgent: userAgent,
    proxy: '',
    connectionTimeout: connectionTimeout,
    maxConnectionsPerHost: maxConnectionsPerHost,
  );
  addTearDown(client.close);
  return client;
}

/// Starts an HTTP server on the IPv4 loopback address that is closed when the
/// test is complete.
Future<HttpServer> startServer(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) => unawaited(handler(request)));
  addTearDown(() => server.close(force: true));
  return server;
}

Uri serverUrl(HttpServer server, [String path = '/']) =>
    Uri.parse('http://127.0.0.1:${server.port}$path');

/// Starts a server that calls [handler] with each connection after it receives
/// the headers of a request, and then closes the connection.
Future<ServerSocket> startSocketServer(
  Future<void> Function(Socket socket) handler,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <Socket>[];
  server.listen((socket) {
    sockets.add(socket);
    final received = <int>[];
    var handled = false;
    socket.listen((data) {
      received.addAll(data);
      if (!handled && latin1.decode(received).contains('\r\n\r\n')) {
        handled = true;
        unawaited(
          handler(
            socket,
          ).then((_) => socket.close()).catchError((_) => socket.destroy()),
        );
      }
    }, onError: (_) {});
  });
  addTearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  return server;
}

/// Starts a server that sends [response] after it receives the headers of a
/// request, and then closes the connection.
Future<ServerSocket> startRawServer(String response) =>
    startSocketServer((socket) async => socket.add(latin1.encode(response)));

/// Matches a [CurlClientException] with the given libcurl error code.
Matcher isCurlClientException(int code) =>
    isA<CurlClientException>().having((e) => e.code, 'code', code);

/// A request with a body that is read from a stream, which (unlike
/// [StreamedRequest]) propagates backpressure to the stream.
class StreamRequest extends BaseRequest {
  final Stream<List<int>> _body;

  StreamRequest(super.method, super.url, this._body);

  @override
  ByteStream finalize() {
    super.finalize();
    return ByteStream(_body);
  }
}

/// Returns [length] bytes of pseudo-random data.
Uint8List patternBytes(int length) {
  final bytes = Uint8List(length);
  var state = 0x12345678;
  for (var i = 0; i < length; ++i) {
    // A linear congruential generator.
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = state >> 16;
  }
  return bytes;
}

/// Expects [actual] to contain the same bytes as [expected], without the
/// overhead of comparing large lists with [equals].
void expectBytesEqual(Uint8List actual, Uint8List expected) {
  expect(actual.length, expected.length, reason: 'length');
  for (var i = 0; i < actual.length; ++i) {
    if (actual[i] != expected[i]) {
      fail('Bytes differ at offset $i: ${actual[i]} != ${expected[i]}');
    }
  }
}

/// Sends [bytes] as the body of an HTTP/2 response and ends the stream.
///
/// `package:http2` versions without the fix for
/// https://github.com/dart-lang/http/issues/1998 stall if
/// `sendData(bytes, endStream: true)` sends more data than the peer's flow
/// control window allows, so the data is sent in chunks, followed by an empty
/// DATA frame that ends the stream.
void sendHttp2Body(TransportStream stream, List<int> bytes) {
  const chunkSize = 64 * 1024;
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = i + chunkSize < bytes.length ? i + chunkSize : bytes.length;
    stream.sendData(bytes.sublist(i, end));
  }
  stream.sendData(const [], endStream: true);
}

/// A request received by a [Http2TestServer].
class Http2Request {
  final Map<String, String> headers;
  final Stream<List<int>> body;

  Http2Request(this.headers, this.body);
}

/// An HTTP/2 server, which counts the connections that it accepts.
///
/// The server uses TLS (and so supports HTTP/2 negotiated with ALPN) if
/// `secure` is true and otherwise expects HTTP/2 with prior knowledge.
class Http2TestServer {
  final int port;
  final bool secure;
  final Future<void> Function() _close;
  final _connections = <ServerTransportConnection>[];

  Http2TestServer._(this.port, this.secure, this._close);

  int get connectionCount => _connections.length;

  Uri url(String path) => secure
      ? Uri.parse('https://127.0.0.1:$port$path')
      : Uri.parse('http://127.0.0.1:$port$path');

  static Future<Http2TestServer> start(
    Future<void> Function(Http2Request request, ServerTransportStream stream)
    handler, {
    bool secure = true,
  }) async {
    final Stream<Socket> sockets;
    final Http2TestServer server;
    if (secure) {
      // dart:io servers negotiate the ALPN protocols of the context.
      final context = serverSecurityContext()..setAlpnProtocols(['h2'], true);
      final socket = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      sockets = socket;
      server = Http2TestServer._(socket.port, true, socket.close);
    } else {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      sockets = socket;
      server = Http2TestServer._(socket.port, false, socket.close);
    }
    sockets.listen((socket) {
      final connection = ServerTransportConnection.viaSocket(socket);
      server._connections.add(connection);
      connection.incomingStreams.listen(
        (stream) => _handleStream(stream, handler),
        onError: (_) {},
      );
    }, onError: (_) {});
    addTearDown(server.close);
    return server;
  }

  static void _handleStream(
    ServerTransportStream stream,
    Future<void> Function(Http2Request request, ServerTransportStream stream)
    handler,
  ) {
    final body = StreamController<List<int>>();
    var receivedHeaders = false;
    stream.incomingMessages.listen(
      (message) {
        if (message is HeadersStreamMessage && !receivedHeaders) {
          receivedHeaders = true;
          final headers = {
            for (final header in message.headers)
              ascii.decode(header.name): ascii.decode(header.value),
          };
          unawaited(
            handler(Http2Request(headers, body.stream), stream).catchError((_) {
              stream.terminate();
            }),
          );
        } else if (message is DataStreamMessage) {
          body.add(message.bytes);
        }
        if (message.endStream) unawaited(body.close());
      },
      onError: (Object e) {
        if (!body.isClosed) {
          body.addError(e);
          unawaited(body.close());
        }
      },
      onDone: () {
        if (!body.isClosed) unawaited(body.close());
      },
    );
  }

  Future<void> close() async {
    await _close();
    for (final connection in _connections) {
      await connection.terminate();
    }
  }
}
