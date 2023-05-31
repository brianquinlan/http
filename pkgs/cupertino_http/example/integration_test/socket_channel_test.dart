// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'dart:typed_data';
import 'package:async/async.dart';

void test2() {
  late int port;
  setUpAll(() async {
    final channel = spawnHybridCode(r'''
      import 'dart:io';

      import 'package:stream_channel/stream_channel.dart';

      hybridMain(StreamChannel channel) async {
        var server = await HttpServer.bind('localhost', 0);
        server.transform(WebSocketTransformer()).listen((webSocket) {
          webSocket.listen((request) {
            webSocket.add(request);
          });
        });
        channel.sink.add(server.port);
      }
    ''', stayAlive: true);

    port = await channel.stream.first as int;
  });

  test('communicates using an existing WebSocket', () async {
    final channel =
        CupertinoWebSocketChannel.connect(Uri.parse('ws://localhost:$port'));

    expect(channel.ready, completes);

    addTearDown(channel.sink.close);

    final queue = StreamQueue(channel.stream);
    channel.sink.add('foo');
    expect(await queue.next, 'foo');

    channel.sink.add(Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(
      await queue.next,
      [1, 2, 3, 4, 5],
    );

    channel.sink.add(Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(await queue.next, equals([1, 2, 3, 4, 5]));
  });

// https://developer.apple.com/documentation/foundation/nsurlsessionwebsocketdelegate
  test('.connect with an immediate call to close', () async {
    final server = await HttpServer.bind('localhost', 0);
    final channel = CupertinoWebSocketChannel.connect(
        Uri.parse('ws://localhost:${server.port}'));

    addTearDown(server.close);
    server.transform(WebSocketTransformer()).listen((WebSocket webSocket) {});

    expect(channel.ready, completes);

    print('Sending close!');
    await channel.sink.close(5678, 'raisin');
    await channel.stream.drain<void>();
    print('Drained!');
    expect(channel.closeCode, equals(5678));
    expect(channel.closeReason, equals('raisin'));

/*
    expect(() async {
      print('I cam here!');
      expect(channel.closeCode, equals(5678));
      expect(channel.closeReason, equals('raisin'));
    }(), completes);*/
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('defaultSessionConfiguration', () {
    test2();
  });
}
