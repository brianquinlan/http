// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// Starts an WebSocket server that echos the payload of the request.
///
/// Channel protocol:
///    On Startup:
///     - send port
///    On Request Received:
///     - echoes the request payload
///    When Receive Anything:
///     - exit
void hybridMain(StreamChannel<Object?> channel) async {
  late HttpServer server;

  server = (await HttpServer.bind('localhost', 0))
    ..listen((request) async {
      Duration sleep = Duration.zero;
      if (request.requestedUri.queryParameters.containsKey('sleep')) {
        sleep = Duration(
            seconds: int.parse(request.requestedUri.queryParameters['sleep']!));
      }
      final webSocket = await WebSocketTransformer.upgrade(
        request,
      );

      webSocket.listen((event) {
        channel.sink.add(event);
      }, onDone: () {
        print(
            'Got client close code: ${webSocket.closeCode} ${webSocket.closeReason}');
        if (webSocket.closeCode == 4123) {
          channel.sink.add(null);
          channel.sink.add(null);
        } else {
          channel.sink.add(webSocket.closeCode);
          channel.sink.add(webSocket.closeReason);
        }
      });
      if (sleep.inSeconds > 0) {
        print('Sleeping');
        await Future<void>.delayed(sleep);
        print('Awake');
      }
      webSocket.close(4123, 'server closed the connection');
    });

  channel.sink.add(server.port);
  await channel
      .stream.first; // Any writes indicates that the server should exit.
  unawaited(server.close());
}
