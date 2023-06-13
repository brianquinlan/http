// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:web_socket_channel_conformance_tests/web_socket_channel_conformance_tests.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('defaultSessionConfiguration', () {
    testAll(CupertinoWebSocketChannel.connect);
  });
}
