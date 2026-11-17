// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// To cause a request failure [with a suitable message] due to too many redirects,
// we need to throw an IOException. This cannot be done using Dart JNI bindings,
// which lead to a deadlock and eventually a `java.net.SocketTimeoutException`.
// https://github.com/dart-lang/native/issues/561

package com.example.ok_http

import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.IOException
import java.net.ProtocolException

/**
 * Callback interface utilized by the [RedirectInterceptor].
 *
 * Allows Dart code to operate upon the intermediate redirect responses.
 */
interface RedirectReceivedCallback {
    fun onRedirectReceived(response: Response, location: String)
}


class RedirectInterceptor {
    companion object {

        /**
         * Adds a redirect interceptor to the OkHttpClient.Builder
         *
         * @param clientBuilder The `OkHttpClient.Builder` to add the interceptor to
         * @param maxRedirects The maximum number of redirects to follow
         * @param followRedirects Whether to follow redirects
         *
         * @return OkHttpClient.Builder
         */
        fun addRedirectInterceptor(
            clientBuilder: OkHttpClient.Builder,
            maxRedirects: Int,
            followRedirects: Boolean,
            redirectCallback: RedirectReceivedCallback,
        ): OkHttpClient.Builder {
            return clientBuilder.addInterceptor(Interceptor { chain ->
                var req = chain.request()
                var response = chain.proceed(req)
                var redirectCount = 0

                while (response.isRedirect && followRedirects) {
                    val location = response.header("location") ?: break
                    val newUrl = req.url.resolve(location) ?: run {
                        response.close()
                        throw ProtocolException("Unsupported or invalid redirect location: $location")
                    }

                    if (redirectCount >= maxRedirects) {
                        response.close()
                        throw IOException("Redirect limit exceeded")
                    }

                    val builder = req.newBuilder().url(newUrl)
                    val code = response.code
                    val method = req.method
                    if (((code == 301 || code == 302) && method == "POST") ||
                        (code == 303 && method != "GET" && method != "HEAD")
                    ) {
                        builder.method("GET", null)
                        builder.removeHeader("Transfer-Encoding")
                        builder.removeHeader("Content-Length")
                        builder.removeHeader("Content-Type")
                        builder.removeHeader("Content-Encoding")
                        builder.removeHeader("Content-Language")
                        builder.removeHeader("Content-Location")
                    }

                    if (newUrl.scheme != req.url.scheme ||
                        newUrl.host != req.url.host ||
                        newUrl.port != req.url.port
                    ) {
                        builder.removeHeader("Authorization")
                        builder.removeHeader("WWW-Authenticate")
                        builder.removeHeader("Proxy-Authorization")
                        builder.removeHeader("Proxy-Authenticate")
                        builder.removeHeader("Cookie")
                        builder.removeHeader("Cookie2")
                        builder.removeHeader("Host")
                    }

                    redirectCallback.onRedirectReceived(response, newUrl.toString())

                    req = builder.build()
                    response.close()
                    response = chain.proceed(req)
                    redirectCount++
                }

                response
            })
        }
    }
}
