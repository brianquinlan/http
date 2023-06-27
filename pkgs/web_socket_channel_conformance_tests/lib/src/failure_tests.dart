// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'failure_server_vm.dart'
    if (dart.library.html) 'failure_server_web.dart';

const _isWeb = bool.fromEnvironment('dart.library.html');
const _isVM = bool.fromEnvironment('dart.library.io') &&
    !bool.fromEnvironment('cupertino_http');

/// Tests that the [WebSocketChannel] can correctly transmit and receive text
/// and binary payloads.
void testFailures(
    WebSocketChannel Function(Uri uri, {Iterable<String>? protocols})
        channelFactory) {
  group('failures', () {
    late final Uri uri1;
    late final Uri uri2;
    late final StreamChannel<Object?> httpServerChannel;
    late final StreamQueue<Object?> httpServerQueue;

    setUpAll(() async {
      httpServerChannel = await startServer();
      httpServerQueue = StreamQueue(httpServerChannel.stream);
      uri1 = Uri.parse('ws://localhost:${await httpServerQueue.next}');
      uri2 = Uri.parse('ws://localhost:${await httpServerQueue.next}');
    });
    tearDownAll(() => httpServerChannel.sink.add(null));

    test('close before upgrade', () async {
      final channel = channelFactory(uri1);

      var sinkDoneComplete = false;
      var sinkDoneOnError = false;
      var streamOnData = false;
      var streamOnDone = false;
      var streamOnError = false;

      channel.sink.done.then((_) {
        sinkDoneComplete = true;
      }, onError: (_) {
        sinkDoneOnError = true;
      });

      channel.stream.listen((_) {
        streamOnData = true;
      }, onError: (_) {
        streamOnError = true;
      }, onDone: () {
        streamOnDone = true;
      });

      await expectLater(
          channel.ready, throwsA(isA<WebSocketChannelException>()));
      channel.sink.add('Hello World!');

      expect(sinkDoneComplete, false);
      expect(sinkDoneOnError, false);
      expect(streamOnData, false);
      expect(streamOnDone, true); // VM false
      expect(streamOnError, true); // VM false
      expect(channel.closeCode, null);
      expect(channel.closeReason, null);
    }, skip: _isVM);

    test('disconnect after upgrade', () async {
      final channel = channelFactory(uri2);

      var sinkDoneComplete = false;
      var sinkDoneOnError = false;
      var streamOnData = false;
      var streamOnDone = false;
      var streamOnError = false;

      channel.sink.done.then((_) {
        sinkDoneComplete = true;
      }, onError: (_) {
        sinkDoneOnError = true;
      });

      channel.stream.listen((_) {
        streamOnData = true;
      }, onError: (_) {
        streamOnError = true;
      }, onDone: () {
        streamOnDone = true;
      });

      await expectLater(channel.ready, completes);
      await Future<void>.delayed(const Duration(seconds: 2));
      channel.sink.add('Hello World!');

      expect(sinkDoneComplete, true); // VM false
      expect(sinkDoneOnError, false);
      expect(streamOnData, false);
      expect(streamOnDone, true);
      expect(streamOnError, false);
      expect(channel.closeCode, 1006); // VM 1005
      expect(channel.closeReason, '');
    }, skip: _isVM);
  });
}
