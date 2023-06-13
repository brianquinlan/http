/// XXX
library;

import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:core' as core;
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'cupertino_api.dart';

class CupertinoWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  late final URLSessionWebSocketTask _task;
  final _sendingController = StreamController<dynamic>();
  final _receivingController = StreamController<dynamic>();
//  final _controller =
//      StreamChannelController<dynamic>(allowForeignErrors: false);

  final Completer<void> _readyCompleter = Completer<void>();

  void handleMessage(URLSessionWebSocketMessage value) {
    late Object v;
    switch (value.type) {
      case URLSessionWebSocketMessageType.urlSessionWebSocketMessageTypeString:
        v = value.string!;
        break;
      case URLSessionWebSocketMessageType.urlSessionWebSocketMessageTypeData:
        v = value.data!.bytes;
        break;
    }
    _receivingController.sink.add(v);
    scheduleReceive();
  }

  void scheduleReceive() {
//    print('scheduleReceive');
    _task.receiveMessage().then(handleMessage, onError: handleError);
  }

  void handleError(Object e, StackTrace? st) {
    _receivingController.sink.addError(e, st);
  }

  CupertinoWebSocketChannel._(Uri uri, URLSessionConfiguration config) {
    final session = URLSession.sessionWithConfiguration(
      config,
      onWebSocketTaskOpened: (session, task, protocol) {
        print('onWebSocketTaskOpened($protocol)');
        _protocol = protocol;
        _readyCompleter.complete();
      },
      onWebSocketTaskClosed: (session, task, code, reason) {
        print('onWebSocketTaskClosed($closeCode, $reason)');
        _closeCode = code;
        _closeReason = reason == null ? null : utf8.decode(reason.bytes);
        _receivingController.sink.close();
      },
    );

    _task = session.webSocketTaskWithRequest(URLRequest.fromUrl(uri))..resume();

    _readyCompleter.future.then((value) {
      scheduleReceive();
      _sendingController.stream.listen((event) {
        late URLSessionWebSocketMessage message;
        if (event is List) {
          final data =
              Data.fromUint8List(Uint8List.fromList(event.cast<int>()));
          message = URLSessionWebSocketMessage.fromData(data);
        } else if (event is String) {
          message = URLSessionWebSocketMessage.fromString(event);
        }
        _task.sendMessage(message).then((value) => null,
            onError: (e) => print('error sending message: $e'));
      }, onDone: () {
        print('Sink closed: $_localCloseCode $_localCloseReason');
        if (_localCloseCode != null) {
          Data? reason;
          if (_localCloseReason != null) {
            reason = Data.fromList(_localCloseReason!.codeUnits);
          }
          print('closing with: $_localCloseCode $_localCloseReason');
          _task.cancelWithCloseCode(_localCloseCode!, reason);
        } else {
          print('doing simple cancel');
          _task.cancel();
        }
      }, onError: (e) {});
    });
  }

  factory CupertinoWebSocketChannel.connect(Uri uri) =>
      CupertinoWebSocketChannel._(
          uri, URLSessionConfiguration.defaultSessionConfiguration());

  int? _localCloseCode;
  String? _localCloseReason;

  int? _closeCode;
  @override
  int? get closeCode => _closeCode;

  String? _closeReason;
  @override
  String? get closeReason => _closeReason;

  String? _protocol;
  @override
  String? get protocol => _protocol;

  @override
  Future<void> get ready => _readyCompleter.future;

  @override
  WebSocketSink get sink => _WebSocketSink(this);

  @override
  Stream<dynamic> get stream => _receivingController.stream;
}

class _WebSocketSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  /// The channel to which this sink belongs.
  final CupertinoWebSocketChannel _channel;

  _WebSocketSink(CupertinoWebSocketChannel channel)
      : _channel = channel,
        super(channel._sendingController.sink);

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    _channel
      .._localCloseCode = closeCode
      .._localCloseReason = closeReason;
    return super.close();
  }

  @override
  void add(dynamic data) {
    if (data is String || data is List<int>) {
      super.add(data);
    } else {
      throw ArgumentError.value(data, 'data', 'must be a String or List<int>');
    }
  }
}
