// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform, ZLibDecoder;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart';

import 'native.dart' as native;

/// The versions of HTTP that a [CurlClient] can use.
enum CurlHttpVersion {
  /// HTTP/1.1.
  http11(native.CurlHttpVersionValue.v1_1),

  /// HTTP/2 for `https` URLs, if the server supports it, and HTTP/1.1
  /// otherwise.
  ///
  /// This is the default.
  http2(native.CurlHttpVersionValue.v2Tls),

  /// HTTP/2 without negotiation, for both `http` and `https` URLs.
  ///
  /// The server must support HTTP/2.
  http2PriorKnowledge(native.CurlHttpVersionValue.v2PriorKnowledge),

  /// HTTP/3, falling back to HTTP/2 or HTTP/1.1 if it fails.
  ///
  /// Requires a build of libcurl with HTTP/3 support.
  http3(native.CurlHttpVersionValue.v3),

  /// Only HTTP/3.
  ///
  /// Requires a build of libcurl with HTTP/3 support.
  http3Only(native.CurlHttpVersionValue.v3Only);

  final int _value;

  const CurlHttpVersion(this._value);
}

/// A [ClientException] for a failed libcurl transfer.
class CurlClientException extends ClientException {
  /// The libcurl error code (a
  /// [`CURLcode`](https://curl.se/libcurl/c/libcurl-errors.html)).
  final int code;

  CurlClientException(super.message, Uri super.uri, this.code);

  @override
  String toString() {
    final b = StringBuffer('CurlClientException: $message [CURLcode $code]');
    if (uri != null) b.write(', uri=$uri');
    return b.toString();
  }
}

/// The libcurl version string, e.g.
/// "libcurl/8.23.0 BoringSSL nghttp2/1.70.0".
String get curlVersion => native.curlVersion;

/// The number of response body bytes that may be received but not yet
/// delivered to the response stream listener before the transfer is paused.
const _receiveWindow = 1024 * 1024;

/// The number of delivered response body bytes after which the native code is
/// notified, which allows it to resume a paused transfer.
const _acknowledgeThreshold = _receiveWindow ~/ 4;

/// The number of request body bytes that may be passed to libcurl but not yet
/// sent before the request body stream is paused.
const _sendWindow = 1024 * 1024;

/// The maximum size of a chunk of request body passed to libcurl at once.
const _maxSendChunk = 256 * 1024;

/// The methods whose semantics anticipate a request body.
///
/// RFC 9110 8.6 says that "A user agent SHOULD NOT send a Content-Length
/// header field when the request message does not contain content and the
/// method semantics do not anticipate such data".
const _methodsWithBody = {'POST', 'PUT', 'PATCH'};

final _tokenRegExp = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
final _invalidHeaderValueRegExp = RegExp('[\r\n\x00]');

/// A [Client] based on [libcurl](https://curl.se/libcurl/).
///
/// libcurl, and the libraries that it uses (BoringSSL for TLS and nghttp2
/// for HTTP/2), are compiled from source and bundled with the application
/// using Dart native assets.
///
/// Each [CurlClient] has its own pool of connections and a native thread that
/// performs its transfers. [close] must be called to release them.
///
/// For example:
/// ```dart
/// import 'package:curl_http/curl_http.dart';
///
/// void main() async {
///   final client = CurlClient();
///   try {
///     final response = await client.get(Uri.https('dart.dev'));
///     print(response.statusCode);
///   } finally {
///     client.close();
///   }
/// }
/// ```
class CurlClient extends BaseClient implements Finalizable {
  final Uint8List _config;
  _ClientState? _state;
  bool _closed = false;

  /// Creates a [CurlClient].
  ///
  /// [httpVersion] selects the version of HTTP to use. By default, HTTP/2 is
  /// used for `https` URLs if the server supports it, and HTTP/1.1 otherwise.
  ///
  /// [trustedCertificates] is a list of PEM-encoded certificates of the
  /// certificate authorities to trust when verifying the certificates of
  /// servers. If it is `null` then the certificate authorities trusted by the
  /// operating system are used. Certificates are verified with BoringSSL and,
  /// on Apple platforms, with the Security framework if BoringSSL can't
  /// verify them (e.g. because the certificate authority uses name
  /// constraints for IP addresses).
  ///
  /// If [verifyCertificates] is `false` then the certificates of servers are
  /// not verified. This is insecure and should only be used for testing.
  ///
  /// [userAgent] is the value of the "User-Agent" header that is sent if the
  /// request does not set one. If it is `null` then
  /// `Dart/<version> (package:curl_http)` is used.
  ///
  /// [proxy] is the URL of a proxy to use, e.g. "http://localhost:8080". If
  /// it is `null` then, like `dart:io`'s `HttpClient`, the proxy settings in
  /// the environment variables `http_proxy`, `https_proxy`, `all_proxy` and
  /// `no_proxy` are used. If it is empty then no proxy is used. Hosts that
  /// match [noProxy] (a comma-separated list of host names, see
  /// [`CURLOPT_NOPROXY`](https://curl.se/libcurl/c/CURLOPT_NOPROXY.html)) are
  /// reached directly.
  ///
  /// [connectionTimeout] limits the time taken to establish a connection,
  /// including the TLS handshake.
  ///
  /// [maxConnectionsPerHost] and [maxConnections] limit the number of
  /// simultaneous connections to each host and in total. Requests that
  /// exceed the limit wait for a connection to become available.
  CurlClient({
    CurlHttpVersion? httpVersion,
    List<int>? trustedCertificates,
    bool verifyCertificates = true,
    String? userAgent,
    String? proxy,
    String? noProxy,
    Duration? connectionTimeout,
    int? maxConnectionsPerHost,
    int? maxConnections,
  }) : _config = _encodeConfig(
         httpVersion: httpVersion,
         trustedCertificates: trustedCertificates,
         verifyCertificates: verifyCertificates,
         userAgent: userAgent ?? _defaultUserAgent,
         proxy: proxy,
         noProxy: noProxy,
         connectionTimeout: connectionTimeout,
         maxConnectionsPerHost: maxConnectionsPerHost,
         maxConnections: maxConnections,
       );

  static final String _defaultUserAgent = () {
    final version = RegExp(r'^\d+\.\d+').stringMatch(Platform.version);
    return 'Dart/${version ?? 'unknown'} (package:curl_http)';
  }();

  static Uint8List _encodeConfig({
    required CurlHttpVersion? httpVersion,
    required List<int>? trustedCertificates,
    required bool verifyCertificates,
    required String userAgent,
    required String? proxy,
    required String? noProxy,
    required Duration? connectionTimeout,
    required int? maxConnectionsPerHost,
    required int? maxConnections,
  }) {
    final builder = native.TlvBuilder()
      ..addInt(native.ConfigTag.receiveWindow, _receiveWindow)
      ..addString(native.ConfigTag.userAgent, userAgent);
    if (httpVersion != null) {
      builder.addInt(native.ConfigTag.httpVersion, httpVersion._value);
    }
    if (trustedCertificates != null) {
      builder.addBytes(native.ConfigTag.caCertificates, trustedCertificates);
    }
    if (!verifyCertificates) {
      builder
        ..addInt(native.ConfigTag.verifyPeer, 0)
        ..addInt(native.ConfigTag.verifyHost, 0);
    }
    if (proxy != null) builder.addString(native.ConfigTag.proxy, proxy);
    if (noProxy != null) builder.addString(native.ConfigTag.noProxy, noProxy);
    if (connectionTimeout != null) {
      builder.addInt(
        native.ConfigTag.connectTimeoutMs,
        connectionTimeout.inMilliseconds,
      );
    }
    if (maxConnectionsPerHost != null) {
      builder.addInt(
        native.ConfigTag.maxConnectionsPerHost,
        maxConnectionsPerHost,
      );
    }
    if (maxConnections != null) {
      builder.addInt(native.ConfigTag.maxConnections, maxConnections);
    }
    return builder.takeBytes();
  }

  /// Sends an HTTP request and asynchronously returns the response.
  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    if (_closed) {
      throw ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    final url = request.url;
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw ClientException('Unsupported URL scheme "${url.scheme}".', url);
    }
    if (url.host.isEmpty) {
      throw ClientException('URL has no host.', url);
    }
    final body = request.finalize();
    final state = _state ??= _ClientState(this, _config);
    return _CurlRequest(this, state, request).start(body);
  }

  /// Closes the client and cancels any requests that are in progress.
  ///
  /// Requests in progress complete with a [ClientException], and the streams
  /// of responses that are being received report a [ClientException].
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _state?.close(this);
    _state = null;
  }
}

/// The state of a [CurlClient] that has started a request: its native client
/// and the port that receives updates from it.
///
/// The port handler references this object, but not the [CurlClient], so that
/// a [CurlClient] without requests in progress can be garbage collected, at
/// which point its native client is released by [native.clientFinalizer] and
/// its port is closed by [_portFinalizer].
class _ClientState {
  final RawReceivePort _port;
  final Pointer<native.NativeClient> client;
  final requests = <int, _CurlRequest>{};
  int _nextRequestId = 1;
  bool _closed = false;

  static final _portFinalizer = Finalizer<RawReceivePort>(
    (port) => port.close(),
  );

  factory _ClientState(CurlClient owner, Uint8List config) {
    final port = RawReceivePort(null, 'CurlClient');
    final client = native.clientCreate(port.sendPort.nativePort, config);
    if (client == nullptr) {
      port.close();
      throw ClientException('Failed to create the libcurl client.');
    }
    final state = _ClientState._(port, client);
    port
      ..keepIsolateAlive = false
      ..handler = state._handleMessage;
    native.clientFinalizer.attach(owner, client.cast(), detach: owner);
    _portFinalizer.attach(owner, port, detach: owner);
    return state;
  }

  _ClientState._(this._port, this.client);

  int nextRequestId() => _nextRequestId++;

  void addRequest(_CurlRequest request) {
    requests[request.id] = request;
    if (requests.length == 1) _port.keepIsolateAlive = true;
  }

  void removeRequest(_CurlRequest request) {
    if (requests.remove(request.id) != null && requests.isEmpty) {
      _port.keepIsolateAlive = false;
    }
  }

  void _handleMessage(Object? message) {
    for (final update in message as List<Object?>) {
      final values = update as List<Object?>;
      requests[values[0] as int]?.handleUpdate(values);
    }
  }

  void close(CurlClient owner) {
    if (_closed) return;
    _closed = true;
    for (final request in requests.values.toList()) {
      request.failWithClientClosed();
    }
    requests.clear();
    native.clientFinalizer.detach(owner);
    _portFinalizer.detach(owner);
    native.clientRelease(client);
    _port.close();
  }
}

/// A request in progress.
class _CurlRequest {
  /// Keeps the client alive, and so prevents it from being finalized, while
  /// the request is in progress.
  // ignore: unused_field
  final CurlClient _client;
  final _ClientState _state;
  final BaseRequest _request;
  final int id;
  final _responseCompleter = Completer<StreamedResponse>();

  _BodySender? _bodySender;
  StreamController<List<int>>? _controller;
  ByteConversionSink? _decoder;
  bool _isDeflate = false;
  final _pendingBody = <Uint8List>[];
  int _pendingBodyIndex = 0;
  bool _pendingDone = false;
  Object? _pendingError;
  StackTrace? _pendingStackTrace;
  int _unacknowledged = 0;

  /// Whether the native request is complete (or cancelled), so no more updates
  /// will be received.
  bool _nativeDone = false;

  /// Whether the response stream is closed, or the request failed.
  bool _finished = false;

  _CurlRequest(this._client, this._state, this._request)
    : id = _state.nextRequestId();

  Uri get _url => _request.url;

  /// Starts the request and returns the response.
  ///
  /// The response future is returned synchronously, so that it already has a
  /// listener when it completes with an error.
  Future<StreamedResponse> start(ByteStream body) {
    if (_request case Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.whenComplete(_abort));
    }
    unawaited(_begin(body).catchError(_fail));
    return _responseCompleter.future;
  }

  Future<void> _begin(ByteStream body) async {
    // Let the abort trigger callback run first if the trigger had already
    // completed when the request was sent.
    await Future<void>.value();
    final request = _request;
    final method = request.method;
    var hasBody = false;
    var contentLength = -1;
    Stream<List<int>>? stream = body;
    Uint8List? bytes;
    if (method == 'HEAD') {
      // HEAD requests can't have a body.
      unawaited(body.drain<void>().catchError((_) {}));
      stream = null;
    } else if (request is Request) {
      bytes = request.bodyBytes;
      hasBody = bytes.isNotEmpty || _methodsWithBody.contains(method);
      contentLength = bytes.length;
      unawaited(body.drain<void>().catchError((_) {}));
      stream = null;
    } else {
      // Like dart:io, only start the request once body data is available, so
      // that no request is sent if it is aborted before its body starts. Only
      // send a body if the stream is not empty, or if the method anticipates
      // one (with "Content-Length: 0").
      final (nonEmpty, rest) = await _peek(body);
      stream = rest;
      if (nonEmpty) {
        hasBody = true;
        contentLength = request.contentLength ?? -1;
      } else {
        contentLength = request.contentLength ?? 0;
        hasBody = contentLength > 0 || _methodsWithBody.contains(method);
      }
      // Let pending events run first, so that the request is not started if
      // it was aborted at the same time as its body started.
      await Future<void>.delayed(Duration.zero);
    }

    if (_finished) {
      // Aborted before the request was started.
      if (stream != null) unawaited(stream.drain<void>().catchError((_) {}));
      return;
    }

    final Uint8List spec;
    try {
      spec = _encodeRequest(hasBody, contentLength);
    } catch (e) {
      if (stream != null) unawaited(stream.drain<void>().catchError((_) {}));
      rethrow;
    }

    _state.addRequest(this);
    final status = native.startRequest(_state.client, id, spec);
    if (status != native.NativeStatus.ok) {
      _state.removeRequest(this);
      _nativeDone = true;
      if (stream != null) unawaited(stream.drain<void>().catchError((_) {}));
      throw ClientException(
        'Failed to start the request (status $status).',
        _url,
      );
    }

    if (hasBody) {
      _bodySender = bytes != null
          ? _BodySender.bytes(this, bytes)
          : _BodySender.stream(this, stream!);
    } else if (stream != null) {
      // A bodyless request whose stream still needs to be consumed.
      unawaited(stream.drain<void>().catchError((_) {}));
    }
  }

  /// Returns whether [stream] contains any data, and a stream with the same
  /// data.
  static Future<(bool, Stream<List<int>>)> _peek(
    Stream<List<int>> stream,
  ) async {
    final controller = StreamController<List<int>>(sync: true);
    final hasData = Completer<bool>();
    late final StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (data) {
        if (data.isEmpty) return;
        if (!hasData.isCompleted) {
          hasData.complete(true);
          subscription.pause();
        }
        controller.add(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!hasData.isCompleted) hasData.complete(true);
        controller.addError(error, stackTrace);
      },
      onDone: () {
        if (!hasData.isCompleted) hasData.complete(false);
        controller.close();
      },
    );
    controller
      ..onListen = subscription.resume
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    return (await hasData.future, controller.stream);
  }

  Uint8List _encodeRequest(bool hasBody, int contentLength) {
    final request = _request;
    final builder = native.TlvBuilder()
      ..addString(native.RequestTag.method, request.method)
      ..addString(native.RequestTag.url, request.url.toString());
    var hasAcceptEncoding = false;
    var hasConnection = false;
    request.headers.forEach((name, value) {
      if (!_tokenRegExp.hasMatch(name)) {
        throw ClientException('Invalid header name "$name".', _url);
      }
      if (_invalidHeaderValueRegExp.hasMatch(value)) {
        throw ClientException('Invalid value for header "$name".', _url);
      }
      final lowerName = name.toLowerCase();
      if (lowerName == 'accept-encoding') hasAcceptEncoding = true;
      if (lowerName == 'connection') hasConnection = true;
      // libcurl removes headers with an empty value unless they end with a
      // semicolon instead of a colon.
      builder.addString(
        native.RequestTag.header,
        value.isEmpty ? '$name;' : '$name: $value',
      );
    });
    if (!hasAcceptEncoding) {
      // Responses with these encodings are decoded in [_onHeaders].
      builder.addString(
        native.RequestTag.header,
        'Accept-Encoding: gzip, deflate',
      );
    }
    if (!request.persistentConnection && !hasConnection) {
      builder.addString(native.RequestTag.header, 'Connection: close');
    }
    var flags = 0;
    if (request.followRedirects) flags |= native.RequestFlag.followRedirects;
    if (hasBody) flags |= native.RequestFlag.hasBody;
    if (!request.persistentConnection) {
      flags |= native.RequestFlag.closeConnection;
    }
    builder
      ..addInt(native.RequestTag.flags, flags)
      ..addInt(native.RequestTag.maxRedirects, request.maxRedirects)
      ..addInt(native.RequestTag.contentLength, contentLength);
    return builder.takeBytes();
  }

  void handleUpdate(List<Object?> update) {
    final headers = update[1] as List<Object?>?;
    final body = update[2] as Uint8List?;
    final consumed = update[3] as int;
    final done = update[4] as List<Object?>?;
    if (consumed > 0) _bodySender?.onConsumed(consumed);
    if (done != null) {
      _nativeDone = true;
      _state.removeRequest(this);
      _bodySender?.stop();
    }
    if (_finished) return;
    if (headers != null) _onHeaders(headers);
    if (body != null) {
      _pendingBody.add(body);
      _deliver();
    }
    if (done != null) _onDone(done[0] as int, done[1] as String);
  }

  void _onHeaders(List<Object?> headers) {
    final statusCode = headers[0] as int;
    final lines = latin1.decode(headers[1] as Uint8List);
    final effectiveUrl = headers[2] as String?;
    final redirectCount = headers[3] as int;

    final parsed = _parseHeaders(lines);
    final responseHeaders = parsed.headers;
    final contentEncoding = responseHeaders['content-encoding']
        ?.trim()
        .toLowerCase();
    if (_request.method != 'HEAD' &&
        (contentEncoding == 'gzip' ||
            contentEncoding == 'x-gzip' ||
            contentEncoding == 'deflate')) {
      _isDeflate = contentEncoding == 'deflate';
      // The decoder is created when the first data is received, because
      // "deflate" data may or may not have a zlib header.
      _decoder = _PendingDecoder();
    }

    int? contentLength;
    if (_decoder == null && !responseHeaders.containsKey('transfer-encoding')) {
      if (responseHeaders['content-length'] case final value?) {
        contentLength = int.tryParse(value);
        if (contentLength != null && contentLength < 0) contentLength = null;
      }
    }

    final location = responseHeaders['location'];
    final isRedirect =
        !_request.followRedirects &&
        statusCode >= 300 &&
        statusCode < 400 &&
        location != null;

    final version = parsed.version;
    final connection = responseHeaders['connection']?.toLowerCase() ?? '';
    final persistentConnection = switch (version) {
      'HTTP/1.0' => connection.contains('keep-alive'),
      'HTTP/1.1' => !connection.contains('close'),
      _ => true,
    };

    final url = redirectCount > 0 && effectiveUrl != null
        ? Uri.parse(effectiveUrl)
        : _url;

    final controller = _controller = StreamController<List<int>>(
      onListen: _deliver,
      onResume: _deliver,
      onCancel: _cancel,
    );
    _responseCompleter.complete(
      _CurlStreamedResponse(
        controller.stream,
        statusCode,
        url: url,
        contentLength: contentLength,
        request: _request,
        headers: responseHeaders,
        isRedirect: isRedirect,
        persistentConnection: persistentConnection,
        reasonPhrase: parsed.reasonPhrase,
      ),
    );
  }

  void _onDone(int code, String message) {
    if (code == native.CurlCode.ok) {
      if (!_responseCompleter.isCompleted) {
        _fail(CurlClientException('No response received.', _url, code));
        return;
      }
      _pendingDone = true;
    } else {
      final (error, stackTrace) = _errorFor(code, message);
      if (!_responseCompleter.isCompleted) {
        _finished = true;
        _responseCompleter.completeError(error, stackTrace);
        return;
      }
      _pendingError = error;
      _pendingStackTrace = stackTrace;
    }
    _deliver();
  }

  (Object, StackTrace) _errorFor(int code, String message) {
    final bodyError = _bodySender?.error;
    if (bodyError != null) {
      return (bodyError, _bodySender!.stackTrace ?? StackTrace.current);
    }
    if (code == native.CurlCode.tooManyRedirects) {
      return (
        ClientException('Redirect limit exceeded', _url),
        StackTrace.current,
      );
    }
    return (CurlClientException(message, _url, code), StackTrace.current);
  }

  /// Delivers pending response data to the response stream, as long as the
  /// stream has a listener that is not paused.
  void _deliver() {
    final controller = _controller;
    if (controller == null || _finished) return;
    var delivered = 0;
    while (controller.hasListener && !controller.isPaused) {
      if (_pendingBodyIndex < _pendingBody.length) {
        final data = _pendingBody[_pendingBodyIndex++];
        delivered += data.length;
        _addBody(data);
        if (_finished) return;
        continue;
      }
      _pendingBody.clear();
      _pendingBodyIndex = 0;
      if (_pendingError != null) {
        _decoder = null;
        controller.addError(_pendingError!, _pendingStackTrace);
        _close();
      } else if (_pendingDone) {
        if (_closeDecoder()) _close();
      }
      break;
    }
    if (delivered > 0 && !_nativeDone) {
      _unacknowledged += delivered;
      if (_unacknowledged >= _acknowledgeThreshold) {
        native.acknowledge(_state.client, id, _unacknowledged);
        _unacknowledged = 0;
      }
    }
  }

  void _addBody(Uint8List data) {
    var decoder = _decoder;
    if (decoder == null) {
      _controller!.add(data);
      return;
    }
    try {
      if (decoder is _PendingDecoder) {
        decoder = _decoder = _createDecoder(data);
      }
      decoder.add(data);
    } catch (e) {
      _decodingFailed(e);
    }
  }

  ByteConversionSink _createDecoder(Uint8List firstChunk) {
    // "deflate" should be zlib-wrapped (RFC 9110 8.4.1.2) but some servers
    // send raw deflate data.
    final raw =
        _isDeflate &&
        firstChunk.length >= 2 &&
        !((firstChunk[0] & 0x0f) == 8 &&
            ((firstChunk[0] << 8) | firstChunk[1]) % 31 == 0);
    return ZLibDecoder(raw: raw).startChunkedConversion(_DecodedSink(this));
  }

  /// Closes the decoder, if any, and returns whether the response stream can
  /// be closed.
  bool _closeDecoder() {
    final decoder = _decoder;
    _decoder = null;
    if (decoder == null || decoder is _PendingDecoder) return true;
    try {
      decoder.close();
      return true;
    } catch (e) {
      _decodingFailed(e);
      return false;
    }
  }

  void _decodingFailed(Object error) {
    _decoder = null;
    _controller!.addError(
      ClientException('Failed to decode the response body: $error', _url),
    );
    _close();
    _cancelNative();
  }

  void _close() {
    _finished = true;
    _pendingBody.clear();
    _pendingBodyIndex = 0;
    unawaited(_controller!.close());
  }

  void _cancelNative() {
    if (_nativeDone) return;
    _nativeDone = true;
    native.cancelRequest(_state.client, id);
    _state.removeRequest(this);
  }

  void _fail(Object error) {
    _finished = true;
    _cancelNative();
    _bodySender?.stop();
    if (!_responseCompleter.isCompleted) {
      _responseCompleter.completeError(error);
    } else {
      final controller = _controller!;
      _pendingBody.clear();
      _pendingBodyIndex = 0;
      _decoder = null;
      if (!controller.isClosed) {
        controller.addError(error);
        unawaited(controller.close());
      }
    }
  }

  /// Called when the response stream subscription is cancelled.
  void _cancel() {
    _finished = true;
    _pendingBody.clear();
    _pendingBodyIndex = 0;
    _decoder = null;
    _cancelNative();
    _bodySender?.stop();
  }

  void _abort() {
    if (_finished) return;
    _fail(RequestAbortedException(_url));
  }

  /// Called when the client is closed while the request is in progress.
  void failWithClientClosed() {
    // The native client is released, which cancels the request.
    _nativeDone = true;
    if (_finished) return;
    _fail(
      ClientException('Client closed while the request was in progress.', _url),
    );
  }
}

/// A placeholder for a decoder that is created when the first data arrives.
class _PendingDecoder implements ByteConversionSink {
  @override
  void add(List<int> chunk) => throw StateError('Not created');

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) =>
      throw StateError('Not created');

  @override
  void close() {}
}

/// Receives the output of a response body decoder.
class _DecodedSink implements Sink<List<int>> {
  final _CurlRequest _request;

  _DecodedSink(this._request);

  @override
  void add(List<int> data) {
    if (data.isNotEmpty) _request._controller!.add(data);
  }

  @override
  void close() {}
}

/// Sends the body of a request to libcurl, applying backpressure to the body
/// stream.
class _BodySender {
  final _CurlRequest _request;
  final Uint8List? _bytes;
  int _bytesOffset = 0;
  StreamSubscription<List<int>>? _subscription;
  final _queue = <Uint8List>[];
  bool _streamDone = false;
  bool _stopped = false;
  bool _ended = false;
  int _outstanding = 0;

  /// The error reported by the body stream, if any.
  Object? error;
  StackTrace? stackTrace;

  _BodySender.bytes(this._request, Uint8List bytes) : _bytes = bytes {
    _send();
  }

  _BodySender.stream(this._request, Stream<List<int>> stream) : _bytes = null {
    _subscription = stream.listen(
      (data) {
        if (_stopped || data.isEmpty) return;
        final bytes = data is Uint8List ? data : Uint8List.fromList(data);
        for (var i = 0; i < bytes.length; i += _maxSendChunk) {
          final end = i + _maxSendChunk < bytes.length
              ? i + _maxSendChunk
              : bytes.length;
          _queue.add(
            i == 0 && end == bytes.length
                ? bytes
                : Uint8List.sublistView(bytes, i, end),
          );
        }
        _send();
      },
      onError: (Object e, StackTrace s) {
        if (_stopped) return;
        error = e;
        stackTrace = s;
        _end(error: true);
        // Keep draining the stream so that writes to it don't fail.
        _stopped = true;
      },
      onDone: () {
        _streamDone = true;
        _send();
      },
    );
  }

  Pointer<native.NativeClient> get _client => _request._state.client;

  void _send() {
    if (_stopped) return;
    final bytes = _bytes;
    if (bytes != null) {
      while (_outstanding < _sendWindow && _bytesOffset < bytes.length) {
        final end = _bytesOffset + _maxSendChunk < bytes.length
            ? _bytesOffset + _maxSendChunk
            : bytes.length;
        _sendChunk(Uint8List.sublistView(bytes, _bytesOffset, end));
        _bytesOffset = end;
      }
      if (_bytesOffset == bytes.length) _end();
      return;
    }
    while (_outstanding < _sendWindow && _queue.isNotEmpty) {
      _sendChunk(_queue.removeAt(0));
    }
    final subscription = _subscription!;
    if (_outstanding >= _sendWindow) {
      if (!subscription.isPaused) subscription.pause();
    } else if (subscription.isPaused) {
      subscription.resume();
    }
    if (_streamDone && _queue.isEmpty) _end();
  }

  void _sendChunk(Uint8List chunk) {
    _outstanding += chunk.length;
    native.sendBody(_client, _request.id, chunk);
  }

  void _end({bool error = false}) {
    if (_ended) return;
    _ended = true;
    native.endBody(_client, _request.id, error ? 1 : 0);
  }

  /// Called when libcurl has read [length] bytes of the body.
  void onConsumed(int length) {
    _outstanding -= length;
    _send();
  }

  /// Stops sending the body, e.g. because the request is complete or was
  /// aborted. The body stream is drained so that writes to it don't fail.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _queue.clear();
    final subscription = _subscription;
    if (subscription != null && subscription.isPaused) subscription.resume();
  }
}

/// A [StreamedResponse] with the URL of the response.
///
/// This class can be removed when `package:http` v2 is released.
class _CurlStreamedResponse extends StreamedResponse
    implements BaseResponseWithUrl {
  @override
  final Uri url;

  _CurlStreamedResponse(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });
}

/// Parses the status line and header lines of a response, as received from
/// libcurl.
({String version, String? reasonPhrase, Map<String, String> headers})
_parseHeaders(String text) {
  final lines = text.split('\n');
  var statusLine = lines.isEmpty ? '' : lines.first;
  if (statusLine.endsWith('\r')) {
    statusLine = statusLine.substring(0, statusLine.length - 1);
  }
  // E.g. "HTTP/1.1 200 OK" or "HTTP/2 200".
  final statusParts = statusLine.split(' ');
  final version = statusParts.first;
  var reasonPhrase = statusParts.length > 2
      ? statusParts.sublist(2).join(' ').trim()
      : '';

  final headers = <String, String>{};
  String? previousName;
  for (var i = 1; i < lines.length; ++i) {
    var line = lines[i];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) continue;
    final first = line.codeUnitAt(0);
    if (first == 0x20 || first == 0x09) {
      // An obsolete folded header (RFC 9110 5.5): append the continuation to
      // the previous value, separated by a space.
      final continuation = _sanitize(_trim(line));
      if (previousName != null && continuation.isNotEmpty) {
        final value = headers[previousName]!;
        headers[previousName] = value.isEmpty
            ? continuation
            : '$value $continuation';
      }
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) {
      previousName = null;
      continue;
    }
    final name = _trim(line.substring(0, colon)).toLowerCase();
    final value = _sanitize(_trim(line.substring(colon + 1)));
    final existing = headers[name];
    headers[name] = existing == null ? value : '$existing, $value';
    previousName = name;
  }
  if (version.startsWith('HTTP/2') || version.startsWith('HTTP/3')) {
    reasonPhrase = '';
  }
  return (
    version: version,
    reasonPhrase: reasonPhrase.isEmpty ? null : reasonPhrase,
    headers: headers,
  );
}

/// Removes leading and trailing spaces and tabs.
String _trim(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x09;

/// Replaces CR and NUL characters with spaces, as required by RFC 9110 5.5.
String _sanitize(String value) => value.contains(RegExp('[\r\x00]'))
    ? value.replaceAll(RegExp('[\r\x00]'), ' ')
    : value;
