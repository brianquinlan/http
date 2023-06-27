import 'package:web_socket_channel_conformance_tests/web_socket_channel_conformance_tests.dart';

import 'package:test/test.dart';

import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  testAll(WebSocketChannel.connect);
}
