// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// The interface between `package:curl_http` and libcurl.
//
// Each client owns a libcurl multi handle, which is driven by a dedicated
// worker thread. Dart sends commands to the worker thread (start a request,
// send request body data, acknowledge received response data, cancel a
// request...) through the functions declared below, which only enqueue the
// command and wake the worker thread. The worker thread performs all transfers
// and reports their progress by posting messages to a Dart port with
// `Dart_PostCObject`.
//
// None of the functions block, so they can be called from Dart as leaf calls.
//
// Messages
// --------
//
// Each message posted to the client's port is a list of updates, one for each
// request that made progress since the last message:
//
//   [id, headers, body, bodyConsumed, done]
//
//   * id (int): the request identifier passed to
//     `curl_http_client_start_request`.
//   * headers (List or null): the final response headers, sent at most once:
//       [statusCode, headerLines, effectiveUrl, redirectCount, httpVersion,
//        contentLength]
//     `headerLines` (Uint8List) contains the raw status line and header lines
//     as received from libcurl (each terminated by CRLF or LF, unfolded).
//     `contentLength` is -1 if unknown.
//   * body (Uint8List or null): response body data. The receiver must report
//     the length of the data that it has processed with
//     `curl_http_client_acknowledge`, otherwise the transfer is paused once
//     the receive window is full.
//   * bodyConsumed (int): the number of request body bytes, sent with
//     `curl_http_client_send_body`, that libcurl has read since the last
//     update.
//   * done (List or null): the request is complete: [curlCode, message].
//     `curlCode` is 0 (CURLE_OK) on success. No further updates are sent for
//     the request.
//
// Configuration and request specifications
// ----------------------------------------
//
// The client configuration and request specifications are encoded as a
// sequence of tag-length-value entries: a 32-bit tag, a 32-bit length and then
// `length` bytes of value, all in host byte order. Integer values are 64-bit
// integers in host byte order. String values are not NUL-terminated. See the
// `kConfig*` and `kRequest*` constants in `curl_http.c` and
// `lib/src/native.dart`.

#ifndef CURL_HTTP_CURL_HTTP_H_
#define CURL_HTTP_CURL_HTTP_H_

#include <stdint.h>

#include "dart_cobject.h"

#if defined(_WIN32)
#define CURL_HTTP_EXPORT __declspec(dllexport)
#else
#define CURL_HTTP_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CurlHttpClient CurlHttpClient;

// Status codes returned by the functions below.
enum {
  // The operation succeeded.
  kCurlHttpOk = 0,
  // The arguments were invalid (e.g. a malformed request specification).
  kCurlHttpInvalidArgument = 1,
  // Memory could not be allocated.
  kCurlHttpOutOfMemory = 2,
  // The worker thread has stopped (the client has been released).
  kCurlHttpClosed = 3,
  // libcurl could not be initialized or the Dart API version is unsupported.
  kCurlHttpInitializationFailed = 4,
};

// Kinds of native objects counted by `curl_http_live_object_count`.
enum {
  kCurlHttpObjectClients = 0,
  kCurlHttpObjectRequests = 1,
  kCurlHttpObjectCommands = 2,
  kCurlHttpObjectBuffers = 3,
  kCurlHttpObjectThreads = 4,
};

// Initializes the library. Must be called, at least once, before any other
// function. May be called concurrently and repeatedly.
//
// `post_cobject` is the address of `Dart_PostCObject` (`NativeApi.postCObject`)
// and `dart_api_major_version` is `NativeApi.majorVersion`.
CURL_HTTP_EXPORT int32_t curl_http_initialize(
    Dart_PostCObject_Type post_cobject, int64_t dart_api_major_version);

// Returns libcurl's version string, e.g. "libcurl/8.23.0 BoringSSL ...".
CURL_HTTP_EXPORT const char* curl_http_version(void);

// Returns a description of the libcurl error `code` (a CURLcode).
CURL_HTTP_EXPORT const char* curl_http_strerror(int32_t code);

// Creates a client whose updates are posted to `port`.
//
// Returns NULL if the configuration is invalid or the client could not be
// created.
CURL_HTTP_EXPORT CurlHttpClient* curl_http_client_create(Dart_Port port,
                                                         const uint8_t* config,
                                                         int64_t config_length);

// Releases the client: cancels all of its requests, closes its connections
// and stops its worker thread. No further updates are posted.
//
// The client must not be used after this call. May be called from any thread,
// e.g. by a `NativeFinalizer`.
CURL_HTTP_EXPORT void curl_http_client_release(CurlHttpClient* client);

// Starts a request.
//
// `request_id` identifies the request in updates and in the other functions;
// it must be unique for the client. If the request has a body, it must be sent
// with `curl_http_client_send_body` and terminated with
// `curl_http_client_end_body`.
CURL_HTTP_EXPORT int32_t curl_http_client_start_request(CurlHttpClient* client,
                                                        int64_t request_id,
                                                        const uint8_t* spec,
                                                        int64_t spec_length);

// Appends `length` bytes to the body of the request. The data is copied.
CURL_HTTP_EXPORT int32_t curl_http_client_send_body(CurlHttpClient* client,
                                                    int64_t request_id,
                                                    const uint8_t* data,
                                                    int64_t length);

// Marks the end of the body of the request. If `error` is non-zero, the
// request fails instead (e.g. because the Dart body stream failed).
CURL_HTTP_EXPORT int32_t curl_http_client_end_body(CurlHttpClient* client,
                                                   int64_t request_id,
                                                   int32_t error);

// Reports that `length` bytes of response body data, received in updates,
// have been processed. Resumes the transfer if it was paused because the
// receive window was full.
CURL_HTTP_EXPORT int32_t curl_http_client_acknowledge(CurlHttpClient* client,
                                                      int64_t request_id,
                                                      int64_t length);

// Cancels the request. No further updates are posted for it.
CURL_HTTP_EXPORT int32_t curl_http_client_cancel_request(CurlHttpClient* client,
                                                         int64_t request_id);

// Returns the number of live native objects of the given kind (one of the
// `kCurlHttpObject*` constants). Used by tests to detect leaks.
CURL_HTTP_EXPORT int64_t curl_http_live_object_count(int32_t kind);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // CURL_HTTP_CURL_HTTP_H_
