// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:objective_c/objective_c.dart';
import 'package:test/test.dart';

void main() {
  group('assumesHTTP3Capable', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('set', () {
      request.assumesHTTP3Capable = true;
      expect(request.assumesHTTP3Capable, true);
      request.assumesHTTP3Capable = false;
      expect(request.assumesHTTP3Capable, false);
    });
  });

  group('cachePolicy', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('set', () {
      request.cachePolicy =
          NSURLRequestCachePolicy.NSURLRequestReturnCacheDataDontLoad;
      expect(
        request.cachePolicy,
        NSURLRequestCachePolicy.NSURLRequestReturnCacheDataDontLoad,
      );
      request.toString(); // Just verify that there is no crash.
    });
  });

  group('headers', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('empty', () => expect(request.allHttpHeaderFields, null));
    test('add', () {
      request.setValueForHttpHeaderField('header', 'value');
      expect(request.allHttpHeaderFields!['header'], 'value');
      request.toString(); // Just verify that there is no crash.
    });
    test('remove', () {
      request
        ..setValueForHttpHeaderField('cookie', 'foo=bar')
        ..setValueForHttpHeaderField('Cookie', null);
      expect(request.allHttpHeaderFields, isEmpty);
    });
  });

  group('fromUrlRequest', () {
    test('copies request and allows mutation', () {
      final original = URLRequest.fromUrl(
        Uri.parse('http://www.example.com/foo'),
      );
      final copy = MutableURLRequest.fromUrlRequest(original)
        ..httpMethod = 'POST'
        ..setValueForHttpHeaderField('X-Test', '1');
      expect(original.httpMethod, 'GET');
      expect(copy.httpMethod, 'POST');
      expect(copy.allHttpHeaderFields, {'X-Test': '1'});
    });
  });

  group('httpShouldHandleCookies', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('set', () {
      expect(request.httpShouldHandleCookies, true);
      request.httpShouldHandleCookies = false;
      expect(request.httpShouldHandleCookies, false);
    });
  });

  group('body', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('empty', () => expect(request.httpBody, null));
    test('set', () {
      request.httpBody = [1, 2, 3].toNSData();
      expect(request.httpBody!.toList(), Uint8List.fromList([1, 2, 3]));
      request.toString(); // Just verify that there is no crash.
    });
    test('set to null', () {
      request
        ..httpBody = [1, 2, 3].toNSData()
        ..httpBody = null;
      expect(request.httpBody, null);
    });
  });

  group('http method', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('empty', () => expect(request.httpMethod, 'GET'));
    test('set', () {
      request.httpMethod = 'POST';
      expect(request.httpMethod, 'POST');
      request.toString(); // Just verify that there is no crash.
    });
  });

  group('timeoutInterval', () {
    final uri = Uri.parse('http://www.example.com/foo?baz=3#bar');
    late MutableURLRequest request;

    setUp(() => request = MutableURLRequest.fromUrl(uri));

    test('set', () {
      request.timeoutInterval = const Duration(seconds: 23);
      expect(request.timeoutInterval, const Duration(seconds: 23));
      request.toString(); // Just verify that there is no crash.
    });
  });
}
