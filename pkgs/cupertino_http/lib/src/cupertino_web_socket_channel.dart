import 'dart:async';
import 'dart:typed_data';

import 'package:async/src/stream_sink_transformer.dart';
import 'package:stream_channel/src/stream_channel_transformer.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'cupertino_api.dart';

class CupertinoWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final _task = URLSession.sharedSession()
      .webSocketTaskWithRequest(URLRequest.fromUrl(Uri.parse('foo')))
    ..resume();
//  final _receiveController = StreamController<dynamic>();
//  final _sendController = StreamController<dynamic>();
  final _controller =
      StreamChannelController<dynamic>(allowForeignErrors: false);

  CupertinoWebSocketChannel() {
    _task.receiveMessage().then((value) {
      _controller.local.sink.add(value);
    }, onError: (Object e) {
      _controller.local.sink.addError(e);
    });

    _controller.local.stream.listen((event) {
      late URLSessionWebSocketMessage message;
      if (event is List) {
        final data = Data.fromUint8List(Uint8List.fromList(event.cast<int>()));
        message = URLSessionWebSocketMessage.fromData(data);
      } else if (event is String) {
        message = URLSessionWebSocketMessage.fromString(event);
      }

      _task.sendMessage(message).then((value) => null);
    }, onDone: () {
      _task.cancel();
    });
  }

  @override
  // TODO: implement closeCode
  int? get closeCode => throw UnimplementedError();

  @override
  // TODO: implement closeReason
  String? get closeReason => throw UnimplementedError();

  @override
  // TODO: implement protocol
  String? get protocol => throw UnimplementedError();

  @override
  // TODO: implement ready
  Future<void> get ready => throw UnimplementedError();

  @override
  // TODO: implement sink
  WebSocketSink get sink => throw UnimplementedError();

  @override
  // TODO: implement stream
  Stream<dynamic> get stream => _controller.foreign.stream;
}
