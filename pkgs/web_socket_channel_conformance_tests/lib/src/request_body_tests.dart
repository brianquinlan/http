// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'request_body_server_vm.dart'
    if (dart.library.html) 'request_body_server_web.dart';

/// Tests that the [Client] correctly implements HTTP requests with bodies e.g.
/// 'POST'.
void testRequestBody(WebSocketChannel Function(Uri uri) channelFactory) {
  group('request body', () {
    late final Uri uri;
    late final StreamChannel<Object?> httpServerChannel;
    late final StreamQueue<Object?> httpServerQueue;

    setUpAll(() async {
      httpServerChannel = await startServer();
      httpServerQueue = StreamQueue(httpServerChannel.stream);
      uri = Uri.parse('ws://localhost:${await httpServerQueue.next}');
    });
    tearDownAll(() => httpServerChannel.sink.add(null));

    test('close immediately', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);
      await channel.sink.close();
      expect(await channel.stream.isEmpty, true);
    });

    test('empty request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);
      channel.sink.add('');
      expect(await channel.stream.first, '');
    });

    test('string request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);
      channel.sink.add("Hello World!");
      expect(await channel.stream.first, "Hello World!");
    });

    test('empty List<int> request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      channel.sink.add(<int>[]);
      expect(await channel.stream.first, <int>[]);
    });

    test('List<int> request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      channel.sink.add([1, 2, 3, 4, 5]);
      expect(await channel.stream.first, [1, 2, 3, 4, 5]);
    });

    test('Uint8List request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      channel.sink.add(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(await channel.stream.first, [1, 2, 3, 4, 5]);
    });

    test('duration request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);
      expect(() => channel.sink.add(const Duration(seconds: 5)),
          throwsArgumentError);
    });

    test('error added to sink', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);
      channel.sink.addError(Exception('what should this do?'));
      await expectLater(channel.sink.close(), throwsException);
    });

    test('alternative string and binary request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      channel.sink.add('Hello ');
      channel.sink.add([1, 2, 3]);
      channel.sink.add('World!');
      channel.sink.add([4, 5]);

      expect(await channel.stream.take(4).toList(), [
        'Hello ',
        [1, 2, 3],
        'World!',
        [4, 5]
      ]);
    });

    test('increasing payload string size', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      final s = StringBuffer('Hello World\n');
      channel.sink.add(s.toString());
      await for (final response in channel.stream) {
        expect(response, s.toString());
        if (s.length >= 10000) {
          await channel.sink.close();
          break;
        }
        s.writeln('HelloWorld');
        channel.sink.add(s.toString());
      }
    });

    test('increasing payload binary size', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      final data = [1, 2, 3, 4, 5];
      channel.sink.add(data);
      await for (final response in channel.stream) {
        expect(response, data);
        if (data.length >= 10000) {
          await channel.sink.close();
          break;
        }
        data.addAll([1, 2, 3, 4, 5]);
        channel.sink.add(data);
      }
    });
  });
}
