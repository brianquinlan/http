// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/failure_tests.dart';
import 'src/close_tests.dart';
import 'src/playload_transfer_tests.dart';
import 'src/protocol_tests.dart';

/// Runs the entire test suite against the given [WebSocketChannel].
void testAll(
    WebSocketChannel Function(Uri uri, {Iterable<String>? protocols})
        channelFactory) {
  testPayloadTransfer(channelFactory);
  testClose(channelFactory);
  testProtocols(channelFactory);
  testFailures(channelFactory);
}
