// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'protocol_server_vm.dart'
    if (dart.library.html) 'protocol_server_web.dart';

const _isWeb = bool.fromEnvironment('dart.library.html');
const _isVM = bool.fromEnvironment('dart.library.io') &&
    !bool.fromEnvironment('cupertino_http');

/// Tests that the [WebSocketChannel] can correctly transmit and receive text
/// and binary payloads.
void testProtocols(
    WebSocketChannel Function(Uri uri, {Iterable<String>? protocols})
        channelFactory) {
  group('protocols', () {
    late final Uri uri;
    late final StreamChannel<Object?> httpServerChannel;
    late final StreamQueue<Object?> httpServerQueue;

    setUpAll(() async {
      httpServerChannel = await startServer();
      httpServerQueue = StreamQueue(httpServerChannel.stream);
      uri = Uri.parse('ws://localhost:${await httpServerQueue.next}');
    });
    tearDownAll(() => httpServerChannel.sink.add(null));

    test('no protocol', () async {
      final channel = channelFactory(
          uri.replace(queryParameters: {'protocol': 'custom-protocol'}));

      await expectLater(channel.ready, completes);

      expect(await httpServerQueue.next, <String>[]);
      expect(channel.protocol, null);
    }, skip: _isWeb);

    test('single protocol', () async {
      final channel = channelFactory(
          uri.replace(queryParameters: {'protocol': 'custom-protocol'}),
          protocols: ['custom-protocol']);

      await expectLater(channel.ready, completes);

      expect(await httpServerQueue.next, ['custom-protocol']);
      expect(channel.protocol, 'custom-protocol');
    });

    test('multiple protocols', () async {
      final channel = channelFactory(
          uri.replace(queryParameters: {'protocol': 'custom-protocol2'}),
          protocols: ['custom-protocol1', 'custom-protocol2']);

      await expectLater(channel.ready, completes);

      expect(
          await httpServerQueue.next, ['custom-protocol1', 'custom-protocol2']);
      expect(channel.protocol, 'custom-protocol2');
    });
  });
}
