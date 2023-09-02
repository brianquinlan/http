import 'dart:async';
import 'dart:developer';

final _developerProfilingData = <HttpClientRequestProfile>[];

// cupertino redirect:
//

final class HttpClientRedirects {}

final class HttpClientEvents {}

// https://snipboard.io/LX5Vnj.jpg
// local port showed in Overview
// connectioninfo is instructured
final class HttpClientRequestProfile {
  // Equivalent to HttpClient.enableTimelineLogging
  static bool profilingEnabled = false;

  final _requestBodyController = StreamController<List<int>>();
  final _responseBodyController = StreamController<List<int>>();

  String? requestMethod;
  String? requestUri;
  // connectionInfo;
  int? requestContentLength;
  Map<String, List<String>>? requestHeaders;

  StreamSink<List<int>> get requestBodySink => _requestBodyController.sink;
  int _lastBodyUpdateTime = 0;

  List<HttpClientRedirects>? redirects;
  List<HttpClientEvents>? events;

  int? statusCode;
  String? reasonPhrase;
  Map<String, List<String>>? responseHeaders;
  StreamSink<List<int>> get responseBodySink => _responseBodyController.sink;

  HttpClientRequestProfile._() {
    _requestBodyController.stream.listen((data) {
      _lastBodyUpdateTime = Timeline.now;
    });
  }

  /// If HTTP profiling is enabled, returns
  /// a [HttpClientRequestProfile] otherwise returns `null`.
  static HttpClientRequestProfile? profile() {
    // Always return `null` in product mode so that the
    // profiling code can be tree shaken away.
    if (const bool.fromEnvironment('dart.vm.product') || !profilingEnabled) {
      return null;
    }
    final requestProfile = HttpClientRequestProfile._();
    // Stores the profiling data privately.
    _developerProfilingData.add(requestProfile);
    return requestProfile;
  }
}
