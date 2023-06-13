/// Support for doing something awesome.
///
/// More dartdocs go here.
library;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'src/request_body_tests.dart';

// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Runs the entire test suite against the given [Client].
///
/// If [canStreamRequestBody] is `false` then tests that assume that the
/// [Client] supports sending HTTP requests with unbounded body sizes will be
/// skipped.
//
/// If [canStreamResponseBody] is `false` then tests that assume that the
/// [Client] supports receiving HTTP responses with unbounded body sizes will
/// be skipped
///
/// If [redirectAlwaysAllowed] is `true` then tests that require the [Client]
/// to limit redirects will be skipped.
///
/// If [canWorkInIsolates] is `false` then tests that require that the [Client]
/// work in Isolates other than the main isolate will be skipped.
///
/// The tests are run against a series of HTTP servers that are started by the
/// tests. If the tests are run in the browser, then the test servers are
/// started in another process. Otherwise, the test servers are run in-process.
void testAll(WebSocketChannel Function(Uri uri) channelFactory) {
  testRequestBody(channelFactory);
}
