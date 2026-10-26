A [package:http][] `Client` based on [libcurl][].

libcurl, and the libraries that it uses ([BoringSSL][] for TLS and
[nghttp2][] for HTTP/2), are compiled from source when the package is built,
using a [build hook][], and are bundled with the application. No libraries
need to be installed on the system that runs it.

> [!NOTE]
> This package is experimental and is not published on pub.dev.

## Features

* HTTP/1.1 and HTTP/2, including multiplexing of requests over a single
  connection, HTTP/2 negotiated with ALPN and HTTP/2 with prior knowledge.
* Connection pooling, with optional limits on the number of connections.
* TLS with BoringSSL. Server certificates are verified with the operating
  system's certificate store, or with the certificate authorities that you
  provide. On Apple platforms, certificate chains that BoringSSL can't verify
  (e.g. chains whose certificate authority uses name constraints for IP
  addresses) are verified with the Security framework, as `dart:io` does.
* Streaming request and response bodies with flow control, so that large
  transfers use a bounded amount of memory.
* Transparent decoding of `gzip` and `deflate` response bodies.
* Proxies, configured explicitly or with the `http_proxy`, `https_proxy`,
  `all_proxy` and `no_proxy` environment variables (like `dart:io`'s
  `HttpClient`).
* Abortable requests ([package:http `Abortable`][]).
* Redirects, including `307` and `308` redirects of requests with a body.

## Using

```dart
import 'package:curl_http/curl_http.dart';
import 'package:http/http.dart';

void main() async {
  final Client client = CurlClient();
  try {
    final response = await client.get(Uri.https('dart.dev'));
    print('${response.statusCode}: ${response.body.length} characters');
  } finally {
    client.close();
  }
}
```

`CurlClient` can be configured when it is created:

| Parameter | Description |
| --- | --- |
| `httpVersion` | The HTTP version to use (`CurlHttpVersion`). By default, HTTP/2 is used for `https` URLs if the server supports it, and HTTP/1.1 otherwise. |
| `trustedCertificates` | PEM-encoded certificates of the certificate authorities to trust, instead of those trusted by the operating system. |
| `verifyCertificates` | Whether to verify server certificates. Disabling verification is insecure. |
| `userAgent` | The default `User-Agent` header. |
| `proxy`, `noProxy` | The proxy to use, and the hosts that bypass it. By default the proxy environment variables are used; an empty `proxy` disables proxies. |
| `connectionTimeout` | The maximum time to establish a connection, including the TLS handshake. |
| `maxConnectionsPerHost`, `maxConnections` | Limits on the number of simultaneous connections. |

Each `CurlClient` has its own connection pool and a native thread that
performs its transfers, so reuse a single client for many requests and call
`close()` when you are done with it. Clients that are not closed are released
when they are garbage collected, once their requests are complete.

## Building

The build hook in `hook/build.dart` builds the native code with:

* [CMake][] 3.16 or later, which must be on the `PATH`.
* A C and C++ compiler. On macOS, install the Xcode command line tools. On
  Linux, install GCC or Clang.

The first build takes about a minute. Later builds are incremental.

The build is supported on macOS (arm64 and x64), iOS, Android and Linux
(without cross-compiling). It has only been tested on macOS. Windows is not
supported yet.

### Vendored libraries

The sources of libcurl, BoringSSL and nghttp2 are vendored in
`third_party/`; see `third_party/*/VENDORED.md` for their versions. To update
them, change the versions and hashes in `tool/vendor_third_party.sh` and run
it.

## Design

* Requests are performed by a native worker thread per client, using the
  libcurl [multi interface][]. Dart calls non-blocking native functions to
  queue commands (start a request, send part of a request body, acknowledge
  received data, cancel a request) for the worker thread.
* The worker thread posts the responses to Dart with `Dart_PostCObject`.
  Large response body chunks are transferred to Dart without being copied.
* At most 1 MiB of response body data that hasn't been delivered to the
  response stream listener is buffered for each request. When the limit is
  reached, the transfer is paused, which applies backpressure to the server.
  Similarly, at most 1 MiB of request body data is buffered, and the request
  body stream is paused when the limit is reached.

## Limitations

* HTTP/3 is not supported. `CurlHttpVersion.http3` and
  `CurlHttpVersion.http3Only` require a build of libcurl with HTTP/3 support.
* The trailers and informational (`1xx`) responses of HTTP responses are
  ignored, because package:http doesn't support them.
* Request bodies larger than 1 MiB can't be sent again when following a `307`
  or `308` redirect, or when libcurl retries a request on a new connection.
  Such requests fail with a `CurlClientException` with code 65
  (`CURLE_SEND_FAIL_REWIND`).
* Cookies are not stored. Use the `Cookie` and `Set-Cookie` headers.
* On platforms other than macOS and iOS, certificates are only verified with
  BoringSSL, which rejects certificates issued by certificate authorities that
  use name constraints for IP addresses (as `dart:io` does on those
  platforms).

## Testing

```shell
dart test
```

runs the [package:http_client_conformance_tests][] tests, tests of the
features of `CurlClient` and tests that check that native resources are
released. On macOS, `tool/leak_check.dart` checks a workload for native
memory leaks with the `leaks` tool.

[BoringSSL]: https://boringssl.googlesource.com/boringssl
[build hook]: https://dart.dev/tools/hooks
[CMake]: https://cmake.org
[libcurl]: https://curl.se/libcurl/
[multi interface]: https://curl.se/libcurl/c/libcurl-multi.html
[nghttp2]: https://nghttp2.org
[package:http]: https://pub.dev/packages/http
[package:http `Abortable`]: https://pub.dev/documentation/http/latest/http/Abortable-class.html
[package:http_client_conformance_tests]: https://github.com/dart-lang/http/tree/master/pkgs/http_client_conformance_tests
