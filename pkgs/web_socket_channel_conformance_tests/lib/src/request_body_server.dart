// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// Starts an HTTP server that captures the content type header and request
/// body.
///
/// Channel protocol:
///    On Startup:
///     - send port
///    On Request Received:
///     - send "Content-Type" header
///     - send request body
///    When Receive Anything:
///     - exit
void hybridMain(StreamChannel<Object?> channel) async {
  late HttpServer server;

  server = (await HttpServer.bind('localhost', 0))
    ..transform(WebSocketTransformer()).listen((WebSocket webSocket) {
      print('Got a connection!');
      webSocket.listen(webSocket.add);
      print('Done listening!');
    });

  channel.sink.add(server.port);
  await channel
      .stream.first; // Any writes indicates that the server should exit.
  unawaited(server.close());
}
