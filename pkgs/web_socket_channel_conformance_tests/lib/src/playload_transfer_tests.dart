// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'echo_server_vm.dart' if (dart.library.html) 'echo_server_web.dart';

const _isWeb = bool.fromEnvironment('dart.library.html');
const _isVM = bool.fromEnvironment('dart.library.io') &&
    !bool.fromEnvironment('cupertino_http');

/// Tests that the [WebSocketChannel] can correctly transmit and receive text
/// and binary payloads.
void testPayloadTransfer(
    WebSocketChannel Function(Uri uri, {Iterable<String>? protocols})
        channelFactory) {
  group('payload transfer', () {
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
      expect(await channel.stream.isEmpty,
          true); // Stream can't be listened to at this point.
    }, skip: _isVM);

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
    }, skip: _isWeb);

    test('List<int> request and response', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      channel.sink.add([1, 2, 3, 4, 5]);
      expect(await channel.stream.first, [1, 2, 3, 4, 5]);
    }, skip: _isWeb);

    test('List<int> with >255 value', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      expect(() => channel.sink.add([1, 2, 256, 4, 5]), throwsArgumentError);
    }, skip: _isWeb || _isVM);

    test('List<int> with <0 value', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      expect(() => channel.sink.add([1, 2, 256, 4, 5]), throwsArgumentError);
    }, skip: _isWeb || _isVM);

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
    }, skip: _isWeb || _isVM);

    test('error added to sink', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      expect(() => channel.sink.addError(Exception('what should this do?')),
          throwsUnsupportedError);
      await channel.sink.close();
      expect(channel.stream.isEmpty, true);
    }, skip: _isWeb || _isVM);

    test('add after error', () async {
      final channel = channelFactory(uri);

      await expectLater(channel.ready, completes);

      expect(() => channel.sink.addError(Exception('what should this do?')),
          throwsUnsupportedError);

      channel.sink.add('Hello World!');
      expect(await channel.stream.first, 'Hello World!');
    }, skip: _isWeb || _isVM);

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
    }, skip: _isWeb);

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
    }, skip: _isWeb);
  });
}
