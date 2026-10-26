// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A [package:http](https://pub.dev/packages/http) `Client` based on
/// [libcurl](https://curl.se/libcurl/).
library;

export 'src/curl_client.dart'
    show CurlClient, CurlClientException, CurlHttpVersion, curlVersion;
