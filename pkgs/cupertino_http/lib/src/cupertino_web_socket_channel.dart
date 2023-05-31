import 'dart:async';
import 'dart:typed_data';
import 'package:async/async.dart';

import 'package:async/src/stream_sink_transformer.dart';
import 'package:stream_channel/src/stream_channel_transformer.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'cupertino_api.dart';

class CupertinoWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final URLSessionWebSocketTask _task;
//  final _receiveController = StreamController<dynamic>();
//  final _sendController = StreamController<dynamic>();
  final _controller =
      StreamChannelController<dynamic>(allowForeignErrors: false);

  void handleMessage(URLSessionWebSocketMessage value) {
    print('received: $value');
    late Object v;
    switch (value.type) {
      case URLSessionWebSocketMessageType.urlSessionWebSocketMessageTypeString:
        v = value.string!;
        break;
      case URLSessionWebSocketMessageType.urlSessionWebSocketMessageTypeData:
        v = value.data!.bytes;
        break;
    }
    _controller.local.sink.add(v);
    _task.receiveMessage().then(handleMessage, onError: handleError);
  }

  void handleError(Object e) {
    print('received error: $e');
    _controller.local.sink.addError(e);
  }

  CupertinoWebSocketChannel._(URLSessionWebSocketTask task) : _task = task {
    _task.receiveMessage().then(handleMessage, onError: handleError);

    _controller.local.stream.listen((event) {
      late URLSessionWebSocketMessage message;
      if (event is List) {
        final data = Data.fromUint8List(Uint8List.fromList(event.cast<int>()));
        message = URLSessionWebSocketMessage.fromData(data);
      } else if (event is String) {
        message = URLSessionWebSocketMessage.fromString(event);
      }
      print('Sending: $message');
      _task.sendMessage(message).then((value) => null,
          onError: (e) => print('error sending message: $e'));
    }, onDone: () {
      if (_localCloseCode != null) {
        Data? reason;
        if (_localCloseReason != null) {
          reason = Data.fromList(_localCloseReason!.codeUnits);
        }
        _task.cancelWithCloseCode(_localCloseCode!, reason);
      } else {
        _task.cancel();
      }
    });
  }

  factory CupertinoWebSocketChannel.connect(Uri uri) {
    final task = URLSession.sharedSession()
        .webSocketTaskWithRequest(URLRequest.fromUrl(uri))
      ..resume();
    return CupertinoWebSocketChannel._(task);
  }

  int? _localCloseCode;
  String? _localCloseReason;

  int? _closeCode;
  @override
  int? get closeCode => _task.closeCode;

  String? _closeReason;
  @override
  String? get closeReason => _closeReason;

  @override
  // TODO: implement protocol
  String? get protocol => throw UnimplementedError();

  @override
  Future<void> get ready => Future.value();

  @override
  WebSocketSink get sink => _WebSocketSink(this);

  @override
  Stream<dynamic> get stream => _controller.foreign.stream;
}

class _WebSocketSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  /// The channel to which this sink belongs.
  final CupertinoWebSocketChannel _channel;

  _WebSocketSink(CupertinoWebSocketChannel channel)
      : _channel = channel,
        super(channel._controller.foreign.sink);

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    _channel
      .._localCloseCode = closeCode
      .._localCloseReason = closeReason;
    return super.close();
  }
}
