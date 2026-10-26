// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:curl_http/curl_http.dart';
import 'package:http/http.dart';

/// Fetches information about a package from pub.dev.
///
/// Usage: `dart run example/curl_http_example.dart [package]`
Future<void> main(List<String> arguments) async {
  final package = arguments.isEmpty ? 'http' : arguments.first;
  print('Using $curlVersion');

  // Code that uses a `Client` works with any implementation, e.g. an
  // `IOClient`, so `CurlClient` can be used on some platforms only.
  final Client client = CurlClient(userAgent: 'curl_http example');
  try {
    final response = await client.get(
      Uri.https('pub.dev', '/api/packages/$package'),
    );
    if (response.statusCode != 200) {
      stderr.writeln('Request failed with status ${response.statusCode}.');
      exitCode = 1;
      return;
    }
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final latest = json['latest'] as Map<String, Object?>;
    final pubspec = latest['pubspec'] as Map<String, Object?>;
    print('$package ${latest['version']}: ${pubspec['description']}');
  } on ClientException catch (e) {
    stderr.writeln('Request failed: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}
