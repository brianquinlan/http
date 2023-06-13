// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/playload_transfer_tests.dart';

/// Runs the entire test suite against the given [WebSocketChannel].
void testAll(WebSocketChannel Function(Uri uri) channelFactory) {
  testPayloadTransfer(channelFactory);
}
