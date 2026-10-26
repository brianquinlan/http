// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:curl_http/curl_http.dart';
import 'package:http_client_conformance_tests/http_client_conformance_tests.dart';
import 'package:test/test.dart';

void main() {
  group('CurlClient', () {
    testAll(
      CurlClient.new,
      canReceiveSetCookieHeaders: true,
      canSendCookieHeaders: true,
      preservesMethodCase: true,
      supportsAbort: true,
    );
  });

  group('CurlClient HTTP/1.1', () {
    testAll(
      () => CurlClient(httpVersion: CurlHttpVersion.http11),
      canReceiveSetCookieHeaders: true,
      canSendCookieHeaders: true,
      preservesMethodCase: true,
      supportsAbort: true,
    );
  });
}
