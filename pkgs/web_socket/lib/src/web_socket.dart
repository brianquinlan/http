// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'connect_stub.dart'
    if (dart.library.js_interop) 'browser_web_socket.dart'
    if (dart.library.io) 'io_web_socket.dart' as connector;

/// An event received from the peer through the [WebSocket].
sealed class WebSocketEvent {}

/// The interface for WebSocket connections.
///
/// To handle potential errors, such as a closed connection, you can use a
/// `try-catch` block to catch the [WebSocketConnectionClosed] exception. This
/// exception is thrown if you attempt to send data or close the [WebSocket] when
/// the connection is no longer open.
///
/// Example:

/// Text data received from the peer through the [WebSocket].
///
/// This event is emitted when the WebSocket receives a text message.
///
/// See [WebSocket.events].
final class TextDataReceived extends WebSocketEvent {
  /// The received text data.
  final String text;
  TextDataReceived(this.text);

  @override
  bool operator ==(Object other) =>
      other is TextDataReceived && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// Binary data received from the peer through the [WebSocket].
///
/// This event is emitted when the WebSocket receives a binary message.
///
/// See [WebSocket.events].
final class BinaryDataReceived extends WebSocketEvent {
  /// The received binary data.
  final Uint8List data;
  BinaryDataReceived(this.data);

  @override
  bool operator ==(Object other) {
    if (other is BinaryDataReceived && other.data.length == data.length) {
      for (var i = 0; i < data.length; ++i) {
        if (other.data[i] != data[i]) return false;
      }
      return true;
    }
    return false;
  }

  @override
  int get hashCode => data.hashCode;

  @override
  String toString() => 'BinaryDataReceived($data)';
}

/// A close notification (Close frame) received from the peer through the
/// [WebSocket] or a failure indication.
///
/// This event is emitted when the WebSocket connection is closed, either by the
/// server or the client.
///
/// See [WebSocket.events].
final class CloseReceived extends WebSocketEvent {
  /// A numerical code indicating the reason why the WebSocket was closed.
  ///
  /// The meaning of the code is defined in
  /// [RFC-6455 7.4](https://www.rfc-editor.org/rfc/rfc6455.html#section-7.4).
  /// Common codes include:
  ///
  /// - 1000: Normal closure.
  /// - 1001: Going away.
  /// - 1002: Protocol error.
  /// - 1003: Unsupported data.
  /// - 1005: No status received.
  /// - 1006: Abnormal closure.
  /// - 1007: Invalid frame payload data.
  /// - 1008: Policy violation.
  /// - 1009: Message too big.
  /// - 1010: Extension negotiation failed.
  /// - 1011: Internal server error.
  /// - 3000-3999: Registered extension codes.
  /// - 4000-4999: Application specific codes.
  final int? code;

  /// A textual explanation of the reason why the WebSocket was closed.
  ///
  /// This may be empty if the peer did not specify a reason.
  final String reason;

  CloseReceived([this.code, this.reason = '']);

  @override
  bool operator ==(Object other) =>
      other is CloseReceived && other.code == code && other.reason == reason;

  @override
  int get hashCode => [code, reason].hashCode;

  @override
  String toString() => 'CloseReceived($code, $reason)';
}

class WebSocketException implements Exception {
  final String message;
  WebSocketException([this.message = '']);
}

/// Thrown if [WebSocket.sendText], [WebSocket.sendBytes], or
/// [WebSocket.close] is called when the [WebSocket] is closed.
class WebSocketConnectionClosed extends WebSocketException {
  WebSocketConnectionClosed([super.message = 'Connection Closed']);
}

/// The interface for WebSocket connections.
///
/// ```dart
/// import 'package:web_socket/src/web_socket.dart';
///
/// void main() async {
///   final socket =
///       await WebSocket.connect(Uri.parse('wss://ws.postman-echo.com/raw'));
///
///   socket.events.listen((e) async {
///     switch (e) {
///       case TextDataReceived(text: final text):
///         print('Received Text: $text');
///         await socket.close();
///       case BinaryDataReceived(data: final data):
///         print('Received Binary: $data');
///       case CloseReceived(code: final code, reason: final reason):
///         print('Connection to server closed: $code [$reason]');
///     }
///   });
///
///   socket.sendText('Hello Dart WebSockets! 🎉');
/// }
abstract interface class WebSocket {
  /// Create a new WebSocket connection.
  ///
  /// The URL supplied in [url] must use the scheme ws or wss.
  ///
  /// If provided, the [protocols] argument indicates that subprotocols that
  /// the peer is able to select. See
  /// [RFC-6455 1.9](https://datatracker.ietf.org/doc/html/rfc6455#section-1.9).
  static Future<WebSocket> connect(Uri url, {Iterable<String>? protocols}) =>
      connector.connect(url, protocols: protocols);

  /// Sends text data to the connected peer.
  ///
  /// Throws [WebSocketConnectionClosed] if the [WebSocket] is
  /// closed (either through [close] or by the peer).
  ///
  /// Data sent through [sendText] will be silently discarded if the peer is
  /// disconnected but the disconnect has not yet been detected.
  void sendText(String s);

  /// Sends binary data to the connected peer.
  ///
  /// Throws [WebSocketConnectionClosed] if the [WebSocket] is
  /// closed (either through [close] or by the peer).
  ///
  /// Data sent through [sendBytes] will be silently discarded if the peer is
  /// disconnected but the disconnect has not yet been detected.
  void sendBytes(Uint8List b);

  /// Closes the WebSocket connection and the [events] `Stream`.
  ///
  /// Sends a Close frame to the peer. If the optional [code] and [reason]
  /// arguments are given, they will be included in the Close frame. If no
  /// [code] is set then the peer will see a 1005 status code. If no [reason]
  /// is set then the peer will not receive a reason string.
  ///
  /// Throws an [ArgumentError] if [code] is not 1000 or in the range 3000-4999.
  ///
  /// Throws an [ArgumentError] if [reason] is longer than 123 bytes when
  /// encoded as UTF-8
  ///
  /// Throws [WebSocketConnectionClosed] if the connection is already
  /// closed (including by the peer).
  Future<void> close([int? code, String? reason]);

  /// A [Stream] of [WebSocketEvent] received from the peer.
  ///
  /// Data received by the peer will be delivered as a [TextDataReceived] or
  /// [BinaryDataReceived].
  ///
  /// If a [CloseReceived] event is received then the [Stream] will be closed. A
  /// [CloseReceived] event indicates either that:
  ///
  /// - A close frame was received from the peer. [CloseReceived.code] and
  ///   [CloseReceived.reason] will be set by the peer.
  /// - A failure occurred (e.g. the peer disconnected). [CloseReceived.code]
  ///   and [CloseReceived.reason] will be a failure code defined by
  ///   (RFC-6455)[https://www.rfc-editor.org/rfc/rfc6455.html#section-7.4.1]
  ///   (e.g. 1006).
  ///
  /// Errors will never appear in this [Stream].
  Stream<WebSocketEvent> get events;

  /// The WebSocket subprotocol negotiated with the peer.
  ///
  /// Will be the empty string if no subprotocol was negotiated.
  ///
  /// See
  /// [RFC-6455 1.9](https://datatracker.ietf.org/doc/html/rfc6455#section-1.9).
  String get protocol;
}
