// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Certificate verification with the Security framework, for Apple platforms.
//
// BoringSSL can't verify some certificate chains that the operating system
// accepts, e.g. chains whose certificate authority restricts the IP addresses
// for which it may issue certificates using name constraints (BoringSSL
// reports "unsupported name constraint type"). On Apple platforms, `dart:io`
// verifies certificates with the Security framework, even if the trusted
// certificates are provided by the application, so `src/curl_http.c` does the
// same if BoringSSL rejects a certificate chain.
//
// This is a separate file because the Security framework's headers and
// BoringSSL's headers can't be included in the same file.

#ifndef CURL_HTTP_APPLE_TRUST_H_
#define CURL_HTTP_APPLE_TRUST_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Creates a set of trusted certificates from DER-encoded certificates.
// Returns NULL if none of the certificates can be decoded.
void* curl_http_apple_anchors_create(const uint8_t* const* certificates,
                                     const size_t* lengths, size_t count);

// Releases a set of trusted certificates created by
// `curl_http_apple_anchors_create`.
void curl_http_apple_anchors_release(void* anchors);

// Returns whether the chain of DER-encoded certificates, starting with the
// server's certificate, is issued by one of the `anchors`, and is valid for
// TLS server authentication.
//
// The host name is not checked; libcurl checks it separately.
bool curl_http_apple_trust_evaluate(void* anchors,
                                    const uint8_t* const* certificates,
                                    const size_t* lengths, size_t count);

#endif  // CURL_HTTP_APPLE_TRUST_H_
