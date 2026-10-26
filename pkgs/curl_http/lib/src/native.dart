// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Bindings to the native library built by `hook/build.dart` from
/// `src/curl_http.c`. See `src/curl_http.h` for documentation.
@DefaultAsset('package:curl_http/curl_http.dart')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// An opaque native client (`CurlHttpClient` in `src/curl_http.h`).
final class NativeClient extends Opaque {}

/// Status codes returned by the native functions.
abstract final class NativeStatus {
  static const ok = 0;
  static const invalidArgument = 1;
  static const outOfMemory = 2;
  static const closed = 3;
  static const initializationFailed = 4;
}

/// Kinds of native objects counted by [liveObjectCount].
abstract final class NativeObjectKind {
  static const clients = 0;
  static const requests = 1;
  static const commands = 2;
  static const buffers = 3;
  static const threads = 4;
}

/// libcurl result codes (`CURLcode`) that are handled specially.
abstract final class CurlCode {
  static const ok = 0;
  static const abortedByCallback = 42;
  static const tooManyRedirects = 47;
}

/// libcurl HTTP versions (`CURL_HTTP_VERSION_*`).
abstract final class CurlHttpVersionValue {
  static const v1_1 = 2;
  static const v2Tls = 4;
  static const v2PriorKnowledge = 5;
  static const v3 = 30;
  static const v3Only = 31;
}

@Native<Int32 Function(Pointer<Void>, Int64)>(
  symbol: 'curl_http_initialize',
  isLeaf: true,
)
external int _initialize(Pointer<Void> postCObject, int dartApiMajorVersion);

@Native<Pointer<Uint8> Function()>(symbol: 'curl_http_version', isLeaf: true)
external Pointer<Uint8> _version();

@Native<Pointer<NativeClient> Function(Int64, Pointer<Uint8>, Int64)>(
  symbol: 'curl_http_client_create',
  isLeaf: true,
)
external Pointer<NativeClient> _clientCreate(
  int port,
  Pointer<Uint8> config,
  int configLength,
);

@Native<Void Function(Pointer<NativeClient>)>(
  symbol: 'curl_http_client_release',
  isLeaf: true,
)
external void clientRelease(Pointer<NativeClient> client);

@Native<Int32 Function(Pointer<NativeClient>, Int64, Pointer<Uint8>, Int64)>(
  symbol: 'curl_http_client_start_request',
  isLeaf: true,
)
external int _startRequest(
  Pointer<NativeClient> client,
  int requestId,
  Pointer<Uint8> spec,
  int specLength,
);

@Native<Int32 Function(Pointer<NativeClient>, Int64, Pointer<Uint8>, Int64)>(
  symbol: 'curl_http_client_send_body',
  isLeaf: true,
)
external int _sendBody(
  Pointer<NativeClient> client,
  int requestId,
  Pointer<Uint8> data,
  int length,
);

@Native<Int32 Function(Pointer<NativeClient>, Int64, Int32)>(
  symbol: 'curl_http_client_end_body',
  isLeaf: true,
)
external int endBody(Pointer<NativeClient> client, int requestId, int error);

@Native<Int32 Function(Pointer<NativeClient>, Int64, Int64)>(
  symbol: 'curl_http_client_acknowledge',
  isLeaf: true,
)
external int acknowledge(Pointer<NativeClient> client, int requestId, int n);

@Native<Int32 Function(Pointer<NativeClient>, Int64)>(
  symbol: 'curl_http_client_cancel_request',
  isLeaf: true,
)
external int cancelRequest(Pointer<NativeClient> client, int requestId);

@Native<Int64 Function(Int32)>(
  symbol: 'curl_http_live_object_count',
  isLeaf: true,
)
external int liveObjectCount(int kind);

/// A finalizer that releases native clients that are not closed.
final clientFinalizer = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<NativeClient>)>>(
    clientRelease,
  ).cast(),
);

var _initialized = false;

/// Initializes the native library, if it hasn't been initialized yet.
void ensureInitialized() {
  if (_initialized) return;
  final status = _initialize(
    NativeApi.postCObject.cast(),
    NativeApi.majorVersion,
  );
  if (status != NativeStatus.ok) {
    throw StateError('Failed to initialize libcurl (status $status).');
  }
  _initialized = true;
}

/// libcurl's version string, e.g. "libcurl/8.23.0 BoringSSL nghttp2/1.70.0".
String get curlVersion {
  ensureInitialized();
  final pointer = _version();
  var length = 0;
  while (pointer[length] != 0) {
    length++;
  }
  return ascii.decode(pointer.asTypedList(length));
}

/// Creates a native client that posts its updates to [port].
Pointer<NativeClient> clientCreate(int port, Uint8List config) {
  ensureInitialized();
  return _clientCreate(port, config.address, config.length);
}

/// Starts a request described by [spec] (encoded with [TlvBuilder]).
int startRequest(Pointer<NativeClient> client, int requestId, Uint8List spec) =>
    _startRequest(client, requestId, spec.address, spec.length);

/// Appends [data] to the body of a request. The data is copied.
int sendBody(Pointer<NativeClient> client, int requestId, Uint8List data) =>
    _sendBody(client, requestId, data.address, data.length);

/// Builds the tag-length-value encoding used for client configurations and
/// request specifications. See `src/curl_http.h`.
class TlvBuilder {
  final _builder = BytesBuilder(copy: false);
  final _header = ByteData(8);

  void _addHeader(int tag, int length) {
    _header
      ..setUint32(0, tag, Endian.host)
      ..setUint32(4, length, Endian.host);
    _builder.add(Uint8List.fromList(_header.buffer.asUint8List()));
  }

  void addInt(int tag, int value) {
    _addHeader(tag, 8);
    final data = ByteData(8)..setInt64(0, value, Endian.host);
    _builder.add(data.buffer.asUint8List());
  }

  void addBytes(int tag, List<int> value) {
    _addHeader(tag, value.length);
    _builder.add(value);
  }

  /// Adds a string, encoded as Latin-1 if possible and otherwise as UTF-8.
  void addString(int tag, String value) {
    final Uint8List bytes;
    if (value.codeUnits.every((c) => c < 0x100)) {
      bytes = latin1.encode(value);
    } else {
      bytes = utf8.encode(value);
    }
    addBytes(tag, bytes);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}

/// The tags of the client configuration entries (`kConfig*` in
/// `src/curl_http.c`).
abstract final class ConfigTag {
  static const httpVersion = 1;
  static const caCertificates = 2;
  static const verifyPeer = 3;
  static const verifyHost = 4;
  static const userAgent = 5;
  static const proxy = 6;
  static const noProxy = 7;
  static const connectTimeoutMs = 8;
  static const maxConnectionsPerHost = 9;
  static const maxConnections = 10;
  static const receiveWindow = 11;
  static const verbose = 12;
  static const bufferSize = 13;
}

/// The tags of the request specification entries (`kRequest*` in
/// `src/curl_http.c`).
abstract final class RequestTag {
  static const method = 1;
  static const url = 2;
  static const header = 3;
  static const flags = 4;
  static const maxRedirects = 5;
  static const contentLength = 6;
}

/// The bits of the [RequestTag.flags] entry.
abstract final class RequestFlag {
  static const followRedirects = 1;
  static const hasBody = 2;
  static const closeConnection = 4;
}
