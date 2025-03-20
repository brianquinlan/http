[![pub package](https://img.shields.io/pub/v/web_socket.svg)](https://pub.dev/packages/web_socket)
[![package publisher](https://img.shields.io/pub/publisher/web_socket.svg)](https://pub.dev/packages/web_socket/publisher)

An easy-to-use library for communicating with
[WebSockets](https://en.wikipedia.org/wiki/WebSocket) that has multiple
implementations.

## Why another WebSocket package?

The goal of `package:web_socket` is to provide a simple, well-defined
[WebSockets](https://en.wikipedia.org/wiki/WebSocket) interface that has
consistent behavior across implementations.

[`package:web_socket_channel`](https://pub.dev/documentation/web_socket_channel/)
is currently the most popular WebSocket package. It has
two implementations, one based on `package:web` and the other based on
`dart:io` `WebSocket`. But those implementations do not have consistent
behavior.

[`WebSocket`](https://pub.dev/documentation/web_socket/latest/web_socket/WebSocket-class.html)
currently has three implementations (with more on the way) that
all pass the same set of
[conformance tests](https://github.com/dart-lang/http/tree/master/pkgs/web_socket_conformance_tests):

* [`BrowserWebSocket`](https://pub.dev/documentation/web_socket/latest/browser_web_socket/BrowserWebSocket-class.html)
* [`CupertinoWebSocket`](https://pub.dev/documentation/cupertino_http/latest/cupertino_http/CupertinoWebSocket-class.html)
* [`IOWebSocket`](https://pub.dev/documentation/web_socket/latest/io_web_socket/IOWebSocket-class.html)

## Using

To establish a WebSocket connection, use the `WebSocket.connect` method:
