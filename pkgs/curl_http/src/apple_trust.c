// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// See `apple_trust.h`.

#include "apple_trust.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

// Appends the certificates that can be decoded to `array` and returns the
// number of certificates that could not be decoded.
static size_t append_certificates(CFMutableArrayRef array,
                                  const uint8_t* const* certificates,
                                  const size_t* lengths, size_t count) {
  size_t failures = 0;
  for (size_t i = 0; i < count; ++i) {
    CFDataRef data =
        CFDataCreate(kCFAllocatorDefault, certificates[i], (CFIndex)lengths[i]);
    SecCertificateRef certificate =
        data != NULL ? SecCertificateCreateWithData(kCFAllocatorDefault, data)
                     : NULL;
    if (data != NULL) CFRelease(data);
    if (certificate == NULL) {
      ++failures;
      continue;
    }
    CFArrayAppendValue(array, certificate);
    CFRelease(certificate);
  }
  return failures;
}

void* curl_http_apple_anchors_create(const uint8_t* const* certificates,
                                     const size_t* lengths, size_t count) {
  CFMutableArrayRef anchors = CFArrayCreateMutable(
      kCFAllocatorDefault, (CFIndex)count, &kCFTypeArrayCallBacks);
  if (anchors == NULL) return NULL;
  append_certificates(anchors, certificates, lengths, count);
  if (CFArrayGetCount(anchors) == 0) {
    CFRelease(anchors);
    return NULL;
  }
  return (void*)anchors;
}

void curl_http_apple_anchors_release(void* anchors) {
  if (anchors != NULL) CFRelease((CFTypeRef)anchors);
}

bool curl_http_apple_trust_evaluate(void* anchors,
                                    const uint8_t* const* certificates,
                                    const size_t* lengths, size_t count) {
  if (anchors == NULL || count == 0) return false;
  bool trusted = false;
  SecTrustRef trust = NULL;
  // The host name is checked by libcurl.
  SecPolicyRef policy = SecPolicyCreateSSL(true, NULL);
  CFMutableArrayRef chain = CFArrayCreateMutable(
      kCFAllocatorDefault, (CFIndex)count, &kCFTypeArrayCallBacks);
  if (policy == NULL || chain == NULL ||
      append_certificates(chain, certificates, lengths, count) != 0) {
    goto done;
  }
  if (SecTrustCreateWithCertificates(chain, policy, &trust) != errSecSuccess) {
    goto done;
  }
  // Only trust the certificates provided by the application.
  if (SecTrustSetAnchorCertificates(trust, (CFArrayRef)anchors) !=
          errSecSuccess ||
      SecTrustSetAnchorCertificatesOnly(trust, true) != errSecSuccess) {
    goto done;
  }
  SecTrustSetNetworkFetchAllowed(trust, false);
  trusted = SecTrustEvaluateWithError(trust, NULL);

done:
  if (trust != NULL) CFRelease(trust);
  if (chain != NULL) CFRelease(chain);
  if (policy != NULL) CFRelease(policy);
  return trusted;
}
