// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Provides access to the
/// [Foundation URL Loading System](https://developer.apple.com/documentation/foundation/url_loading_system).
///
/// **NOTE**: If sandboxed with the App Sandbox (the default Flutter
/// configuration on macOS) then the
/// [`com.apple.security.network.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_network_client)
/// entitlement is required to use `package:cupertino_http`. See
/// [Entitlements and the App Sandbox](https://flutter.dev/to/macos-entitlements).
///
/// # CupertinoClient
///
/// The most convenient way to `package:cupertino_http` it is through
/// [CupertinoClient].
///
/// ```
/// import 'package:cupertino_http/cupertino_http.dart';
///
/// void main() async {
///   var client = CupertinoClient.defaultSessionConfiguration();
///   final response = await client.get(
///       Uri.https('www.googleapis.com', '/books/v1/volumes', {'q': '{http}'}));
///   if (response.statusCode != 200) {
///     throw HttpException('bad response: ${response.statusCode}');
///   }
///
///   final decodedResponse =
///       jsonDecode(utf8.decode(response.bodyBytes)) as Map;
///
///   final itemCount = decodedResponse['totalItems'];
///   print('Number of books about http: $itemCount.');
///   for (var i = 0; i < min(itemCount, 10); ++i) {
///     print(decodedResponse['items'][i]['volumeInfo']['title']);
///   }
/// }
/// ```
///
/// [CupertinoClient] is an implementation of the `package:http` [Client],
/// which means that it can easily used conditionally based on the current
/// platform.
///
/// ```
/// void main() {
///   final Client httpClient;
///   if (Platform.isIOS || Platform.isMacOS) {
///     final config = URLSessionConfiguration.ephemeralSessionConfiguration()
///       ..cache = URLCache.withCapacity(memoryCapacity: 2 * 1024 * 1024)
///       ..httpAdditionalHeaders = {'User-Agent': 'Book Agent'};
///     httpClient = CupertinoClient.fromSessionConfiguration(config);
///   } else {
///     httpClient = IOClient(HttpClient()..userAgent = 'Book Agent');
///   }
///
///   runApp(Provider<Client>(
///       create: (_) => httpClient,
///       child: const BookSearchApp(),
///       dispose: (_, client) => client.close()));
///  }
/// ```
///
/// # NSURLSession API
///
/// `package:cupertino_http` also allows direct access to the
/// [Foundation URL Loading System](https://developer.apple.com/documentation/foundation/url_loading_system)
/// APIs.
///
/// ```
/// void main() {
///   final url = Uri.https('www.example.com', '/');
///   final session = URLSession.sharedSession();
///   final task = session.dataTaskWithCompletionHandler(
///     URLRequest.fromUrl(url),
///       (data, response, error) {
///     if (error == null) {
///       if (response != null && response.statusCode == 200) {
///         print(response);  // Do something with the response.
///         return;
///       }
///     }
///     print(error);  // Handle errors.
///   });
///   task.resume();
/// }
/// ```
library;

import 'package:http/http.dart';

import 'src/cupertino_client.dart';

export 'src/cupertino_api.dart';
export 'src/cupertino_client.dart' show CupertinoClient, NSErrorClientException;
export 'src/cupertino_web_socket.dart';
