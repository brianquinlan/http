// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// See `curl_http.h` for an overview.
//
// Threading model
// ---------------
//
// Each client has a worker thread that owns the client's libcurl multi handle
// and all of its easy handles, `Request`s and response buffers. The only state
// that is shared between threads is the command queue (and the flags next to
// it), which is protected by `CurlHttpClient.mutex`. The functions called by
// Dart allocate a `Command`, append it to the queue and wake the worker thread
// with `curl_multi_wakeup`, which is the only libcurl function that may be
// called from any thread.
//
// Ownership
// ---------
//
// Dart owns the `CurlHttpClient` until it calls `curl_http_client_release`,
// which enqueues a shutdown command. After that the worker thread owns it and
// frees it when it exits. Requests are identified by their id rather than by
// pointer, so Dart can never refer to a freed request.

#include "curl_http.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <curl/curl.h>

#if defined(__APPLE__)
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include "apple_trust.h"
#endif

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

// The tags of the client configuration entries. See `lib/src/native.dart`.
enum {
  kConfigHttpVersion = 1,
  kConfigCaCertificates = 2,
  kConfigVerifyPeer = 3,
  kConfigVerifyHost = 4,
  kConfigUserAgent = 5,
  kConfigProxy = 6,
  kConfigNoProxy = 7,
  kConfigConnectTimeoutMs = 8,
  kConfigMaxConnectionsPerHost = 9,
  kConfigMaxConnections = 10,
  kConfigReceiveWindow = 11,
  kConfigVerbose = 12,
  kConfigBufferSize = 13,
};

// The tags of the request specification entries. See `lib/src/native.dart`.
enum {
  kRequestMethod = 1,
  kRequestUrl = 2,
  kRequestHeader = 3,
  kRequestFlags = 4,
  kRequestMaxRedirects = 5,
  kRequestContentLength = 6,
};

// The bits of the `kRequestFlags` entry.
enum {
  kRequestFlagFollowRedirects = 1,
  kRequestFlagHasBody = 2,
  kRequestFlagCloseConnection = 4,
};

// The default number of response body bytes that may be posted to Dart, but
// not yet acknowledged, before the transfer is paused.
static const int64_t kDefaultReceiveWindow = 1024 * 1024;

// The maximum number of response body bytes that are buffered before they are
// posted to Dart, even if libcurl has more data to deliver.
static const size_t kMaxBodyChunk = 256 * 1024;

// Body data larger than this is posted to Dart as external typed data, which
// transfers the ownership of the buffer to Dart instead of copying it.
static const size_t kExternalTypedDataThreshold = 64 * 1024;

// The maximum number of request body bytes that are retained, after libcurl
// has read them, so that the body can be sent again (e.g. when following a 307
// redirect or when retrying a request on a new connection).
static const size_t kMaxRetainedBody = 1024 * 1024;

// The default value of CURLOPT_BUFFERSIZE (the receive buffer size).
static const long kDefaultBufferSize = 256 * 1024;

//
// Portability.
//

#if defined(_WIN32)

typedef SRWLOCK Mutex;
#define MUTEX_INITIALIZER SRWLOCK_INIT

static void mutex_init(Mutex* mutex) { InitializeSRWLock(mutex); }
static void mutex_destroy(Mutex* mutex) { (void)mutex; }
static void mutex_lock(Mutex* mutex) { AcquireSRWLockExclusive(mutex); }
static void mutex_unlock(Mutex* mutex) { ReleaseSRWLockExclusive(mutex); }

static int64_t atomic_add(volatile int64_t* value, int64_t delta) {
  return InterlockedExchangeAdd64((volatile LONG64*)value, delta) + delta;
}

static int64_t atomic_load(volatile int64_t* value) {
  return InterlockedCompareExchange64((volatile LONG64*)value, 0, 0);
}

typedef DWORD(WINAPI* ThreadFunction)(void*);

static bool thread_start(ThreadFunction function, void* argument) {
  HANDLE thread = CreateThread(NULL, 0, function, argument, 0, NULL);
  if (thread == NULL) return false;
  CloseHandle(thread);
  return true;
}

#define WORKER_RETURN_TYPE DWORD WINAPI
#define WORKER_RETURN_VALUE 0

#else  // defined(_WIN32)

typedef pthread_mutex_t Mutex;
#define MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER

static void mutex_init(Mutex* mutex) { pthread_mutex_init(mutex, NULL); }
static void mutex_destroy(Mutex* mutex) { pthread_mutex_destroy(mutex); }
static void mutex_lock(Mutex* mutex) { pthread_mutex_lock(mutex); }
static void mutex_unlock(Mutex* mutex) { pthread_mutex_unlock(mutex); }

static int64_t atomic_add(volatile int64_t* value, int64_t delta) {
  return __atomic_add_fetch(value, delta, __ATOMIC_SEQ_CST);
}

static int64_t atomic_load(volatile int64_t* value) {
  return __atomic_load_n(value, __ATOMIC_SEQ_CST);
}

typedef void* (*ThreadFunction)(void*);

static bool thread_start(ThreadFunction function, void* argument) {
  pthread_attr_t attributes;
  if (pthread_attr_init(&attributes) != 0) return false;
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  // macOS gives secondary threads 512 KiB of stack by default. libcurl and
  // BoringSSL don't need much more, but be generous.
  pthread_attr_setstacksize(&attributes, 1024 * 1024);
  pthread_t thread;
  const int result = pthread_create(&thread, &attributes, function, argument);
  pthread_attr_destroy(&attributes);
  return result == 0;
}

#define WORKER_RETURN_TYPE void*
#define WORKER_RETURN_VALUE NULL

#endif  // defined(_WIN32)

//
// Global state.
//

static Mutex g_initialize_mutex = MUTEX_INITIALIZER;
static bool g_initialized = false;
static Dart_PostCObject_Type g_post_cobject = NULL;

// Counts of live objects, indexed by the `kCurlHttpObject*` constants.
static volatile int64_t g_live_objects[5];

static void count_object(int32_t kind, int64_t delta) {
  atomic_add(&g_live_objects[kind], delta);
}

static void* allocate(size_t size) { return malloc(size); }

//
// Buffers.
//

typedef struct {
  uint8_t* data;
  size_t length;
  size_t capacity;
} Buffer;

static bool buffer_reserve(Buffer* buffer, size_t additional) {
  if (buffer->capacity - buffer->length >= additional) return true;
  size_t capacity = buffer->capacity == 0 ? 16 * 1024 : buffer->capacity;
  while (capacity - buffer->length < additional) {
    if (capacity > SIZE_MAX / 2) return false;
    capacity *= 2;
  }
  uint8_t* data = (uint8_t*)realloc(buffer->data, capacity);
  if (data == NULL) return false;
  if (buffer->data == NULL) count_object(kCurlHttpObjectBuffers, 1);
  buffer->data = data;
  buffer->capacity = capacity;
  return true;
}

static bool buffer_append(Buffer* buffer, const void* data, size_t length) {
  if (length == 0) return true;
  if (!buffer_reserve(buffer, length)) return false;
  memcpy(buffer->data + buffer->length, data, length);
  buffer->length += length;
  return true;
}

static void buffer_free(Buffer* buffer) {
  if (buffer->data != NULL) {
    free(buffer->data);
    count_object(kCurlHttpObjectBuffers, -1);
  }
  buffer->data = NULL;
  buffer->length = 0;
  buffer->capacity = 0;
}

// Frees a buffer whose ownership was transferred to Dart as external typed
// data. Called by the Dart VM when the typed data is garbage collected.
static void free_external_buffer(void* isolate_callback_data, void* peer) {
  (void)isolate_callback_data;
  free(peer);
  count_object(kCurlHttpObjectBuffers, -1);
}

//
// Tag-length-value parsing.
//

typedef struct {
  const uint8_t* position;
  const uint8_t* end;
} Reader;

// Reads the next entry. Returns 1 if an entry was read, 0 at the end of the
// input and -1 if the input is malformed.
static int reader_next(Reader* reader, uint32_t* tag, const uint8_t** value,
                       uint32_t* length) {
  if (reader->position == reader->end) return 0;
  if ((size_t)(reader->end - reader->position) < 8) return -1;
  memcpy(tag, reader->position, 4);
  memcpy(length, reader->position + 4, 4);
  reader->position += 8;
  if ((size_t)(reader->end - reader->position) < *length) return -1;
  *value = reader->position;
  reader->position += *length;
  return 1;
}

static bool read_int64(const uint8_t* value, uint32_t length, int64_t* result) {
  if (length != 8) return false;
  memcpy(result, value, 8);
  return true;
}

// Returns a NUL-terminated copy of the string value, or NULL if memory could
// not be allocated or the value contains a NUL character.
static char* copy_string(const uint8_t* value, uint32_t length) {
  if (memchr(value, 0, length) != NULL) return NULL;
  char* result = (char*)allocate((size_t)length + 1);
  if (result == NULL) return NULL;
  memcpy(result, value, length);
  result[length] = 0;
  return result;
}

//
// Client configuration.
//

typedef struct {
  long http_version;
  uint8_t* ca_certificates;
  size_t ca_certificates_length;
  bool verify_peer;
  bool verify_host;
  char* user_agent;
  char* proxy;
  char* no_proxy;
  long connect_timeout_ms;
  long max_connections_per_host;
  long max_connections;
  int64_t receive_window;
  bool verbose;
  long buffer_size;
  // A CA bundle found on the file system, if the platform doesn't have a
  // native certificate store that libcurl can use.
  char* ca_file;
  char* ca_path;
#if defined(__APPLE__)
  // `ca_certificates` for the Security framework (see `apple_trust.h`).
  void* apple_anchors;
#endif
} Config;

static void config_free(Config* config) {
  free(config->ca_certificates);
  free(config->user_agent);
  free(config->proxy);
  free(config->no_proxy);
  free(config->ca_file);
  free(config->ca_path);
#if defined(__APPLE__)
  curl_http_apple_anchors_release(config->apple_anchors);
#endif
  memset(config, 0, sizeof(*config));
}

#if !defined(__APPLE__) && !defined(_WIN32) && !defined(__ANDROID__)
static bool file_exists(const char* path) { return access(path, R_OK) == 0; }

static char* copy_c_string(const char* string) {
  const size_t length = strlen(string);
  char* result = (char*)allocate(length + 1);
  if (result != NULL) memcpy(result, string, length + 1);
  return result;
}
#endif

// Locates the trusted certificate authorities for platforms on which libcurl
// can't use the operating system's certificate store directly.
static bool config_find_trust_store(Config* config) {
#if defined(__APPLE__) || defined(_WIN32)
  // libcurl uses the native certificate store (CURLSSLOPT_NATIVE_CA).
  (void)config;
  return true;
#elif defined(__ANDROID__)
  config->ca_path = (char*)allocate(sizeof("/system/etc/security/cacerts"));
  if (config->ca_path == NULL) return false;
  strcpy(config->ca_path, "/system/etc/security/cacerts");
  return true;
#else
  // Like OpenSSL, honor SSL_CERT_FILE and SSL_CERT_DIR.
  const char* file = getenv("SSL_CERT_FILE");
  const char* directory = getenv("SSL_CERT_DIR");
  if (file != NULL && file[0] != 0) {
    config->ca_file = copy_c_string(file);
    if (config->ca_file == NULL) return false;
  }
  if (directory != NULL && directory[0] != 0) {
    config->ca_path = copy_c_string(directory);
    if (config->ca_path == NULL) return false;
  }
  if (config->ca_file != NULL || config->ca_path != NULL) return true;

  // The locations used by common Linux distributions, see
  // https://go.dev/src/crypto/x509/root_linux.go.
  static const char* const kCaFiles[] = {
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/ca-bundle.pem",
      "/etc/pki/tls/cacert.pem",
      "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
      "/etc/ssl/cert.pem",
  };
  for (size_t i = 0; i < sizeof(kCaFiles) / sizeof(kCaFiles[0]); ++i) {
    if (file_exists(kCaFiles[i])) {
      config->ca_file = copy_c_string(kCaFiles[i]);
      return config->ca_file != NULL;
    }
  }
  if (file_exists("/etc/ssl/certs")) {
    config->ca_path = copy_c_string("/etc/ssl/certs");
    return config->ca_path != NULL;
  }
  return true;
#endif
}

#if defined(__APPLE__)
// Creates Security framework anchors from PEM-encoded certificates.
static void* create_apple_anchors(const uint8_t* pem, size_t length) {
  enum { kMaxCertificates = 256 };
  uint8_t* certificates[kMaxCertificates];
  size_t lengths[kMaxCertificates];
  size_t count = 0;
  BIO* bio = BIO_new_mem_buf(pem, (ossl_ssize_t)length);
  if (bio == NULL) return NULL;
  X509* certificate;
  while (count < kMaxCertificates &&
         (certificate = PEM_read_bio_X509(bio, NULL, NULL, NULL)) != NULL) {
    uint8_t* der = NULL;
    const int der_length = i2d_X509(certificate, &der);
    X509_free(certificate);
    if (der_length <= 0) continue;
    certificates[count] = der;
    lengths[count] = (size_t)der_length;
    ++count;
  }
  // Reading stops with an error at the end of the input.
  ERR_clear_error();
  BIO_free(bio);
  void* anchors = curl_http_apple_anchors_create(
      (const uint8_t* const*)certificates, lengths, count);
  for (size_t i = 0; i < count; ++i) OPENSSL_free(certificates[i]);
  return anchors;
}
#endif

static bool config_parse(Config* config, const uint8_t* data, int64_t length) {
  memset(config, 0, sizeof(*config));
  config->http_version = CURL_HTTP_VERSION_NONE;
  config->verify_peer = true;
  config->verify_host = true;
  config->receive_window = kDefaultReceiveWindow;
  config->buffer_size = kDefaultBufferSize;

  if (length < 0 || (length > 0 && data == NULL)) return false;
  Reader reader = {data, data + length};
  uint32_t tag;
  uint32_t value_length;
  const uint8_t* value;
  int result;
  int64_t integer;
  while ((result = reader_next(&reader, &tag, &value, &value_length)) == 1) {
    switch (tag) {
      case kConfigHttpVersion:
        if (!read_int64(value, value_length, &integer)) return false;
        config->http_version = (long)integer;
        break;
      case kConfigCaCertificates:
        free(config->ca_certificates);
        config->ca_certificates = (uint8_t*)allocate(value_length + 1);
        if (config->ca_certificates == NULL) return false;
        memcpy(config->ca_certificates, value, value_length);
        config->ca_certificates_length = value_length;
        break;
      case kConfigVerifyPeer:
        if (!read_int64(value, value_length, &integer)) return false;
        config->verify_peer = integer != 0;
        break;
      case kConfigVerifyHost:
        if (!read_int64(value, value_length, &integer)) return false;
        config->verify_host = integer != 0;
        break;
      case kConfigUserAgent:
        free(config->user_agent);
        config->user_agent = copy_string(value, value_length);
        if (config->user_agent == NULL) return false;
        break;
      case kConfigProxy:
        free(config->proxy);
        config->proxy = copy_string(value, value_length);
        if (config->proxy == NULL) return false;
        break;
      case kConfigNoProxy:
        free(config->no_proxy);
        config->no_proxy = copy_string(value, value_length);
        if (config->no_proxy == NULL) return false;
        break;
      case kConfigConnectTimeoutMs:
        if (!read_int64(value, value_length, &integer)) return false;
        config->connect_timeout_ms = (long)integer;
        break;
      case kConfigMaxConnectionsPerHost:
        if (!read_int64(value, value_length, &integer)) return false;
        config->max_connections_per_host = (long)integer;
        break;
      case kConfigMaxConnections:
        if (!read_int64(value, value_length, &integer)) return false;
        config->max_connections = (long)integer;
        break;
      case kConfigReceiveWindow:
        if (!read_int64(value, value_length, &integer) || integer <= 0) {
          return false;
        }
        config->receive_window = integer;
        break;
      case kConfigVerbose:
        if (!read_int64(value, value_length, &integer)) return false;
        config->verbose = integer != 0;
        break;
      case kConfigBufferSize:
        if (!read_int64(value, value_length, &integer)) return false;
        config->buffer_size = (long)integer;
        break;
      default:
        // Ignore unknown entries.
        break;
    }
  }
  if (result != 0) return false;
  if (config->ca_certificates == NULL) {
    return config_find_trust_store(config);
  }
#if defined(__APPLE__)
  // Without anchors (e.g. if the certificates can't be decoded), certificates
  // are only verified with BoringSSL.
  config->apple_anchors = create_apple_anchors(config->ca_certificates,
                                               config->ca_certificates_length);
#endif
  return true;
}

//
// Commands.
//

typedef enum {
  kCommandStart,
  kCommandBody,
  kCommandEndBody,
  kCommandAcknowledge,
  kCommandCancel,
  kCommandShutdown,
} CommandType;

typedef struct Command {
  struct Command* next;
  CommandType type;
  int64_t request_id;
  // The error flag of kCommandEndBody, or the length of kCommandAcknowledge.
  int64_t value;
  // The length of `data`.
  size_t length;
  // For request body chunks: the number of bytes of `data` read by libcurl.
  size_t offset;
  uint8_t data[];
} Command;

static Command* command_new(CommandType type, int64_t request_id,
                            int64_t value, const uint8_t* data,
                            size_t length) {
  if (length > SIZE_MAX - sizeof(Command)) return NULL;
  Command* command = (Command*)allocate(sizeof(Command) + length);
  if (command == NULL) return NULL;
  command->next = NULL;
  command->type = type;
  command->request_id = request_id;
  command->value = value;
  command->length = length;
  command->offset = 0;
  if (length > 0) memcpy(command->data, data, length);
  count_object(kCurlHttpObjectCommands, 1);
  return command;
}

static void command_free(Command* command) {
  if (command == NULL) return;
  free(command);
  count_object(kCurlHttpObjectCommands, -1);
}

static void command_list_free(Command* command) {
  while (command != NULL) {
    Command* next = command->next;
    command_free(command);
    command = next;
  }
}

//
// Clients and requests.
//

typedef struct Request Request;

struct CurlHttpClient {
  Dart_Port port;
  Config config;
  CURLM* multi;

  // Protects the fields below, which are shared with the threads that call the
  // public functions.
  Mutex mutex;
  Command* queue_head;
  Command* queue_tail;
  // Whether curl_multi_wakeup was called since the worker thread last took the
  // commands from the queue.
  bool wakeup_pending;
  // Whether the worker thread is shutting down. No more commands are accepted.
  bool worker_exiting;

  // The fields below are only accessed by the worker thread.

  // The active requests, in a doubly linked list.
  Request* requests;
  // The requests that have updates to post, in a singly linked list.
  Request* dirty;
  // Whether posting to `port` failed, which means that Dart closed the port
  // (e.g. because the isolate exited without releasing the client).
  bool orphaned;
};

struct Request {
  Request* next;
  Request* previous;
  Request* next_dirty;
  CurlHttpClient* client;
  int64_t id;
  CURL* easy;
  struct curl_slist* headers;
  char error[CURL_ERROR_SIZE];
  bool follow_redirects;
  bool in_multi;
  bool dirty;

  // The request body. Chunks from `body_first` to `body_read` (exclusive) have
  // been read by libcurl and are only retained to be able to rewind the body.
  bool has_body;
  bool body_ended;
  bool body_failed;
  bool body_rewindable;
  bool send_paused;
  Command* body_first;
  Command* body_read;
  Command* body_last;
  size_t body_retained;
  // The number of body bytes that libcurl has read, from the start of the
  // body, and the maximum that it has ever read (it can rewind).
  int64_t body_position;
  int64_t body_high_water;
  // The number of body bytes read but not yet reported to Dart.
  int64_t body_consumed;

  // The response headers.
  Buffer header_lines;
  bool saw_location;
  bool headers_final;
  bool headers_pending;
  long status_code;
  long redirect_count;
  char* effective_url;

  // The response body.
  Buffer body;
  int64_t unacknowledged;
  bool receive_paused;

  // Whether the transfer is complete and `result` is valid.
  bool done;
  CURLcode result;
};

static void mark_dirty(Request* request) {
  if (request->dirty) return;
  request->dirty = true;
  request->next_dirty = request->client->dirty;
  request->client->dirty = request;
}

static Request* find_request(CurlHttpClient* client, int64_t id) {
  for (Request* request = client->requests; request != NULL;
       request = request->next) {
    if (request->id == id) return request;
  }
  return NULL;
}

static void request_free_body_chunks(Request* request) {
  command_list_free(request->body_first);
  request->body_first = NULL;
  request->body_read = NULL;
  request->body_last = NULL;
  request->body_retained = 0;
}

// Frees the request body chunks that have already been read by libcurl and
// stops retaining them.
static void request_release_retained_body(Request* request) {
  while (request->body_first != request->body_read) {
    Command* chunk = request->body_first;
    request->body_first = chunk->next;
    command_free(chunk);
  }
  if (request->body_first == NULL) request->body_last = NULL;
  request->body_retained = 0;
  request->body_rewindable = false;
}

// Removes the request from its client and frees it.
static void request_destroy(Request* request) {
  CurlHttpClient* client = request->client;
  if (request->in_multi) {
    curl_multi_remove_handle(client->multi, request->easy);
    request->in_multi = false;
  }
  if (request->easy != NULL) curl_easy_cleanup(request->easy);
  curl_slist_free_all(request->headers);
  request_free_body_chunks(request);
  buffer_free(&request->header_lines);
  buffer_free(&request->body);
  free(request->effective_url);

  if (request->previous != NULL) {
    request->previous->next = request->next;
  } else {
    client->requests = request->next;
  }
  if (request->next != NULL) request->next->previous = request->previous;

  if (request->dirty) {
    // The request may not be in the list if the list is being flushed.
    for (Request** link = &client->dirty; *link != NULL;
         link = &(*link)->next_dirty) {
      if (*link == request) {
        *link = request->next_dirty;
        break;
      }
    }
  }
  free(request);
  count_object(kCurlHttpObjectRequests, -1);
}

static long pause_bits(const Request* request) {
  long bits = 0;
  if (request->receive_paused) bits |= CURLPAUSE_RECV;
  if (request->send_paused) bits |= CURLPAUSE_SEND;
  return bits;
}

// Completes the request with an error, without involving libcurl.
static void request_fail(Request* request, CURLcode result,
                         const char* message) {
  if (request->in_multi) {
    curl_multi_remove_handle(request->client->multi, request->easy);
    request->in_multi = false;
  }
  if (message != NULL) {
    snprintf(request->error, sizeof(request->error), "%s", message);
  }
  request->done = true;
  request->result = result;
  mark_dirty(request);
}

//
// Posting updates to Dart.
//

// The Dart_CObjects of an update. See `curl_http.h`.
typedef struct {
  Dart_CObject update;
  Dart_CObject* update_values[5];
  Dart_CObject id;
  Dart_CObject headers;
  Dart_CObject body;
  Dart_CObject consumed;
  Dart_CObject done;
  Dart_CObject* headers_values[4];
  Dart_CObject status;
  Dart_CObject lines;
  Dart_CObject url;
  Dart_CObject redirects;
  Dart_CObject* done_values[2];
  Dart_CObject code;
  Dart_CObject message;
} Update;

static void set_null(Dart_CObject* object) { object->type = Dart_CObject_kNull; }

static void set_int(Dart_CObject* object, int64_t value) {
  object->type = Dart_CObject_kInt64;
  object->value.as_int64 = value;
}

static void set_string(Dart_CObject* object, const char* value) {
  object->type = Dart_CObject_kString;
  object->value.as_string = value;
}

static void set_bytes(Dart_CObject* object, const uint8_t* data,
                      size_t length) {
  object->type = Dart_CObject_kTypedData;
  object->value.as_typed_data.type = Dart_TypedData_kUint8;
  object->value.as_typed_data.length = (intptr_t)length;
  // Dart_PostCObject does not accept a NULL pointer, even for empty data.
  static const uint8_t kEmpty[1] = {0};
  object->value.as_typed_data.values = data != NULL ? data : kEmpty;
}

static void set_array(Dart_CObject* object, Dart_CObject** values,
                      intptr_t length) {
  object->type = Dart_CObject_kArray;
  object->value.as_array.length = length;
  object->value.as_array.values = values;
}

static void build_update(Request* request, Update* update) {
  set_array(&update->update, update->update_values, 5);
  update->update_values[0] = &update->id;
  update->update_values[1] = &update->headers;
  update->update_values[2] = &update->body;
  update->update_values[3] = &update->consumed;
  update->update_values[4] = &update->done;

  set_int(&update->id, request->id);

  if (request->headers_pending) {
    set_array(&update->headers, update->headers_values, 4);
    update->headers_values[0] = &update->status;
    update->headers_values[1] = &update->lines;
    update->headers_values[2] = &update->url;
    update->headers_values[3] = &update->redirects;
    set_int(&update->status, request->status_code);
    set_bytes(&update->lines, request->header_lines.data,
              request->header_lines.length);
    if (request->effective_url != NULL) {
      set_string(&update->url, request->effective_url);
    } else {
      set_null(&update->url);
    }
    set_int(&update->redirects, request->redirect_count);
  } else {
    set_null(&update->headers);
  }

  if (request->body.length == 0) {
    set_null(&update->body);
  } else if (request->body.length >= kExternalTypedDataThreshold) {
    update->body.type = Dart_CObject_kExternalTypedData;
    update->body.value.as_external_typed_data.type = Dart_TypedData_kUint8;
    update->body.value.as_external_typed_data.length =
        (intptr_t)request->body.length;
    update->body.value.as_external_typed_data.data = request->body.data;
    update->body.value.as_external_typed_data.peer = request->body.data;
    update->body.value.as_external_typed_data.callback = free_external_buffer;
  } else {
    set_bytes(&update->body, request->body.data, request->body.length);
  }

  set_int(&update->consumed, request->body_consumed);

  if (request->done) {
    set_array(&update->done, update->done_values, 2);
    update->done_values[0] = &update->code;
    update->done_values[1] = &update->message;
    set_int(&update->code, request->result);
    set_string(&update->message, request->error[0] != 0
                                     ? request->error
                                     : curl_easy_strerror(request->result));
  } else {
    set_null(&update->done);
  }
}

// Updates the state of the request after its update was posted (or dropped,
// if `posted` is false).
static void finish_update(Request* request, bool posted) {
  if (request->headers_pending) {
    request->headers_pending = false;
    // The header lines of the final response are no longer needed.
    buffer_free(&request->header_lines);
    free(request->effective_url);
    request->effective_url = NULL;
  }
  if (request->body.length >= kExternalTypedDataThreshold && posted) {
    // Dart now owns the buffer and frees it with `free_external_buffer`.
    request->body.data = NULL;
    request->body.length = 0;
    request->body.capacity = 0;
  } else if (request->body.capacity > kMaxBodyChunk * 2) {
    buffer_free(&request->body);
  } else {
    request->body.length = 0;
  }
  request->body_consumed = 0;
}

// Cancels all requests, e.g. because Dart closed the client's port.
static void cancel_all_requests(CurlHttpClient* client) {
  while (client->requests != NULL) request_destroy(client->requests);
}

// Posts the updates of the given requests in a single message.
//
// May be called from libcurl callbacks, so it must not destroy requests.
static void post_updates(CurlHttpClient* client, Request** requests,
                         size_t count) {
  if (count == 0) return;
  bool posted = false;
  if (!client->orphaned) {
    Update* updates = (Update*)calloc(count, sizeof(Update));
    Dart_CObject** values =
        (Dart_CObject**)calloc(count, sizeof(Dart_CObject*));
    if (updates != NULL && values != NULL) {
      for (size_t i = 0; i < count; ++i) {
        build_update(requests[i], &updates[i]);
        values[i] = &updates[i].update;
      }
      Dart_CObject message;
      set_array(&message, values, (intptr_t)count);
      posted = g_post_cobject(client->port, &message);
    }
    free(updates);
    free(values);
    if (!posted) {
      // Either memory could not be allocated or Dart closed the port (e.g.
      // because the isolate exited). In both cases there is no way to report
      // the progress of the requests, so they are cancelled by
      // `flush_updates`.
      client->orphaned = true;
    }
  }
  for (size_t i = 0; i < count; ++i) {
    finish_update(requests[i], posted);
    requests[i]->dirty = false;
  }
}

// Posts the pending updates of all requests and destroys the requests that
// are complete.
//
// Must not be called from libcurl callbacks.
static void flush_updates(CurlHttpClient* client) {
  size_t count = 0;
  for (Request* request = client->dirty; request != NULL;
       request = request->next_dirty) {
    ++count;
  }
  if (count > 0) {
    Request** requests = (Request**)calloc(count, sizeof(Request*));
    if (requests == NULL) {
      client->orphaned = true;
    } else {
      size_t i = count;
      // The dirty list is in reverse order; post the oldest updates first.
      for (Request* request = client->dirty; request != NULL;
           request = request->next_dirty) {
        requests[--i] = request;
      }
      client->dirty = NULL;
      post_updates(client, requests, count);
      if (!client->orphaned) {
        for (i = 0; i < count; ++i) {
          if (requests[i]->done) request_destroy(requests[i]);
        }
      }
      free(requests);
    }
  }
  if (client->orphaned) cancel_all_requests(client);
}

// Posts the pending update of a single request immediately.
//
// May be called from libcurl callbacks.
static void flush_request(Request* request) {
  CurlHttpClient* client = request->client;
  if (request->dirty) {
    for (Request** link = &client->dirty; *link != NULL;
         link = &(*link)->next_dirty) {
      if (*link == request) {
        *link = request->next_dirty;
        break;
      }
    }
    request->dirty = false;
  }
  post_updates(client, &request, 1);
}

//
// libcurl callbacks.
//

static bool is_blank_line(const char* data, size_t length) {
  return (length == 2 && data[0] == '\r' && data[1] == '\n') ||
         (length == 1 && data[0] == '\n');
}

static bool starts_with_ignoring_case(const char* data, size_t length,
                                      const char* prefix) {
  const size_t prefix_length = strlen(prefix);
  if (length < prefix_length) return false;
  for (size_t i = 0; i < prefix_length; ++i) {
    char c = data[i];
    if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    if (c != prefix[i]) return false;
  }
  return true;
}

// Whether the header line is a "Location" header with a non-empty value,
// which libcurl follows if CURLOPT_FOLLOWLOCATION is set.
static bool is_location_header(const char* data, size_t length) {
  if (!starts_with_ignoring_case(data, length, "location:")) return false;
  for (size_t i = strlen("location:"); i < length; ++i) {
    const char c = data[i];
    if (c != ' ' && c != '\t' && c != '\r' && c != '\n') return true;
  }
  return false;
}

// Parses the status code from the status line at the start of `lines`, e.g.
// "HTTP/1.1 200 OK". Returns -1 if it can't be parsed.
static long parse_status_code(const Buffer* lines) {
  size_t i = 0;
  while (i < lines->length && lines->data[i] != ' ') ++i;
  while (i < lines->length && lines->data[i] == ' ') ++i;
  long code = 0;
  size_t digits = 0;
  for (; i < lines->length && digits < 3; ++i, ++digits) {
    const uint8_t c = lines->data[i];
    if (c < '0' || c > '9') break;
    code = code * 10 + (c - '0');
  }
  return digits == 3 ? code : -1;
}

static void finalize_headers(Request* request) {
  request->headers_final = true;
  request->headers_pending = true;
  long code = parse_status_code(&request->header_lines);
  if (code < 0) {
    code = 0;
    curl_easy_getinfo(request->easy, CURLINFO_RESPONSE_CODE, &code);
  }
  request->status_code = code;
  long redirects = 0;
  curl_easy_getinfo(request->easy, CURLINFO_REDIRECT_COUNT, &redirects);
  request->redirect_count = redirects;
  char* url = NULL;
  curl_easy_getinfo(request->easy, CURLINFO_EFFECTIVE_URL, &url);
  free(request->effective_url);
  request->effective_url = NULL;
  if (url != NULL) {
    const size_t length = strlen(url);
    request->effective_url = (char*)allocate(length + 1);
    if (request->effective_url != NULL) memcpy(request->effective_url, url, length + 1);
  }
  // No request is sent after the final response, so the request body no
  // longer needs to be rewindable.
  request_release_retained_body(request);
  mark_dirty(request);
}

static size_t header_callback(char* data, size_t size, size_t count,
                              void* user_data) {
  Request* request = (Request*)user_data;
  const size_t length = size * count;
  if (request->headers_final) {
    // Trailers, which are not supported by package:http.
    return length;
  }
  if (is_blank_line(data, length)) {
    const long code = parse_status_code(&request->header_lines);
    const bool interim = code >= 100 && code < 200;
    const bool followed = request->follow_redirects && code >= 300 &&
                          code < 400 && request->saw_location;
    if (interim || followed) {
      // Not the final response: an informational (1xx) response, or a
      // redirect that libcurl follows.
      request->header_lines.length = 0;
      request->saw_location = false;
      return length;
    }
    finalize_headers(request);
    return length;
  }
  if (request->header_lines.length > 0 && is_location_header(data, length)) {
    request->saw_location = true;
  }
  if (!buffer_append(&request->header_lines, data, length)) return 0;
  return length;
}

static size_t write_callback(char* data, size_t size, size_t count,
                             void* user_data) {
  Request* request = (Request*)user_data;
  const size_t length = size * count;
  if (!request->headers_final) finalize_headers(request);
  if (!buffer_append(&request->body, data, length)) return CURL_WRITEFUNC_ERROR;
  request->unacknowledged += (int64_t)length;
  mark_dirty(request);
  if (request->body.length >= kMaxBodyChunk) flush_request(request);
  if (request->client->orphaned) return CURL_WRITEFUNC_ERROR;
  if (!request->receive_paused &&
      request->unacknowledged >= request->client->config.receive_window) {
    request->receive_paused = true;
    curl_easy_pause(request->easy, pause_bits(request));
  }
  return length;
}

// Called after libcurl has read the entire `chunk` (which is `body_read`).
static void advance_body_chunk(Request* request, Command* chunk) {
  request->body_read = chunk->next;
  if (request->body_rewindable) {
    request->body_retained += chunk->length;
    if (request->body_retained > kMaxRetainedBody) {
      request_release_retained_body(request);
    }
    return;
  }
  // The chunk is the first in the list, since nothing is retained.
  request->body_first = chunk->next;
  if (request->body_first == NULL) request->body_last = NULL;
  command_free(chunk);
}

static size_t read_callback(char* buffer, size_t size, size_t count,
                            void* user_data) {
  Request* request = (Request*)user_data;
  const size_t capacity = size * count;
  if (request->body_failed) return CURL_READFUNC_ABORT;
  size_t copied = 0;
  while (copied < capacity && request->body_read != NULL) {
    Command* chunk = request->body_read;
    size_t n = chunk->length - chunk->offset;
    if (n > capacity - copied) n = capacity - copied;
    memcpy(buffer + copied, chunk->data + chunk->offset, n);
    chunk->offset += n;
    copied += n;
    if (chunk->offset == chunk->length) advance_body_chunk(request, chunk);
  }
  if (copied > 0) {
    request->body_position += (int64_t)copied;
    if (request->body_position > request->body_high_water) {
      request->body_consumed +=
          request->body_position - request->body_high_water;
      request->body_high_water = request->body_position;
      mark_dirty(request);
    }
    return copied;
  }
  if (request->body_ended) return 0;
  request->send_paused = true;
  return CURL_READFUNC_PAUSE;
}

static int seek_callback(void* user_data, curl_off_t offset, int origin) {
  Request* request = (Request*)user_data;
  if (origin != SEEK_SET || offset != 0 || !request->body_rewindable) {
    return CURL_SEEKFUNC_CANTSEEK;
  }
  for (Command* chunk = request->body_first; chunk != NULL;
       chunk = chunk->next) {
    chunk->offset = 0;
  }
  request->body_read = request->body_first;
  request->body_retained = 0;
  request->body_position = 0;
  return CURL_SEEKFUNC_OK;
}

//
// Request setup.
//

static bool header_has_name(const char* header, const char* name) {
  const size_t length = strlen(name);
  return starts_with_ignoring_case(header, strlen(header), name) &&
         (header[length] == ':' || header[length] == ';');
}

static bool append_header(struct curl_slist** list, const char* header) {
  struct curl_slist* appended = curl_slist_append(*list, header);
  if (appended == NULL) return false;
  *list = appended;
  return true;
}

#define SET_OPTION(option, value)                                \
  do {                                                           \
    CURLcode set_option_result =                                 \
        curl_easy_setopt(request->easy, option, value);          \
    if (set_option_result != CURLE_OK) return set_option_result; \
  } while (0)

#if defined(__APPLE__)
// Appends the DER encoding of `certificate` to `certificates`.
static bool append_der(X509* certificate, uint8_t** certificates,
                       size_t* lengths, size_t* count) {
  uint8_t* der = NULL;
  const int length = i2d_X509(certificate, &der);
  if (length <= 0) return false;
  certificates[*count] = der;
  lengths[*count] = (size_t)length;
  ++*count;
  return true;
}

// Verifies the server's certificate chain with BoringSSL and, if BoringSSL
// rejects it, with the Security framework, trusting only the certificates in
// the client's configuration (see `apple_trust.h`).
static int verify_certificate_chain(X509_STORE_CTX* store_context,
                                    void* argument) {
  const Config* config = (const Config*)argument;
  if (X509_verify_cert(store_context) == 1) return 1;

  X509* leaf = X509_STORE_CTX_get0_cert(store_context);
  if (leaf == NULL) return 0;
  STACK_OF(X509)* chain = X509_STORE_CTX_get0_untrusted(store_context);
  enum { kMaxChainLength = 16 };
  uint8_t* certificates[kMaxChainLength];
  size_t lengths[kMaxChainLength];
  size_t count = 0;
  // The server's certificate must be first.
  bool encoded = append_der(leaf, certificates, lengths, &count);
  const size_t chain_length = chain != NULL ? sk_X509_num(chain) : 0;
  for (size_t i = 0; encoded && i < chain_length && count < kMaxChainLength;
       ++i) {
    X509* certificate = sk_X509_value(chain, i);
    if (X509_cmp(certificate, leaf) == 0) continue;
    encoded = append_der(certificate, certificates, lengths, &count);
  }
  const bool trusted =
      encoded && curl_http_apple_trust_evaluate(
                     config->apple_anchors,
                     (const uint8_t* const*)certificates, lengths, count);
  for (size_t i = 0; i < count; ++i) OPENSSL_free(certificates[i]);
  // Otherwise BoringSSL's error is reported.
  if (!trusted) return 0;
  X509_STORE_CTX_set_error(store_context, X509_V_OK);
  return 1;
}

// Called by libcurl for each TLS connection.
static CURLcode ssl_ctx_callback(CURL* easy, void* ssl_context,
                                 void* user_data) {
  (void)easy;
  SSL_CTX_set_cert_verify_callback((SSL_CTX*)ssl_context,
                                   verify_certificate_chain, user_data);
  return CURLE_OK;
}
#endif

static CURLcode configure_tls(Request* request, const Config* config) {
  if (config->ca_certificates != NULL) {
    struct curl_blob blob;
    blob.data = config->ca_certificates;
    blob.len = config->ca_certificates_length;
    blob.flags = CURL_BLOB_NOCOPY;
    SET_OPTION(CURLOPT_CAINFO_BLOB, &blob);
#if defined(__APPLE__)
    if (config->apple_anchors != NULL && config->verify_peer) {
      SET_OPTION(CURLOPT_SSL_CTX_FUNCTION, ssl_ctx_callback);
      SET_OPTION(CURLOPT_SSL_CTX_DATA, (void*)config);
    }
#endif
  } else {
#if defined(__APPLE__) || defined(_WIN32)
    SET_OPTION(CURLOPT_SSL_OPTIONS, (long)CURLSSLOPT_NATIVE_CA);
#endif
    if (config->ca_file != NULL) SET_OPTION(CURLOPT_CAINFO, config->ca_file);
    if (config->ca_path != NULL) SET_OPTION(CURLOPT_CAPATH, config->ca_path);
  }
  SET_OPTION(CURLOPT_SSL_VERIFYPEER, config->verify_peer ? 1L : 0L);
  SET_OPTION(CURLOPT_SSL_VERIFYHOST, config->verify_host ? 2L : 0L);
  return CURLE_OK;
}

static CURLcode configure_request(Request* request, const Config* config,
                                  const uint8_t* spec, size_t spec_length) {
  char* method = NULL;
  char* url = NULL;
  int64_t flags = 0;
  int64_t max_redirects = 5;
  int64_t content_length = -1;
  bool has_content_type = false;
  bool has_expect = false;
  CURLcode result = CURLE_OK;

  Reader reader = {spec, spec + spec_length};
  uint32_t tag;
  uint32_t value_length;
  const uint8_t* value;
  int status;
  while ((status = reader_next(&reader, &tag, &value, &value_length)) == 1) {
    switch (tag) {
      case kRequestMethod:
        free(method);
        method = copy_string(value, value_length);
        if (method == NULL) result = CURLE_BAD_FUNCTION_ARGUMENT;
        break;
      case kRequestUrl:
        free(url);
        url = copy_string(value, value_length);
        if (url == NULL) result = CURLE_URL_MALFORMAT;
        break;
      case kRequestHeader: {
        char* header = copy_string(value, value_length);
        if (header == NULL) {
          result = CURLE_BAD_FUNCTION_ARGUMENT;
          break;
        }
        if (header_has_name(header, "content-type")) has_content_type = true;
        if (header_has_name(header, "expect")) has_expect = true;
        if (!append_header(&request->headers, header)) {
          result = CURLE_OUT_OF_MEMORY;
        }
        free(header);
        break;
      }
      case kRequestFlags:
        if (!read_int64(value, value_length, &flags)) {
          result = CURLE_BAD_FUNCTION_ARGUMENT;
        }
        break;
      case kRequestMaxRedirects:
        if (!read_int64(value, value_length, &max_redirects)) {
          result = CURLE_BAD_FUNCTION_ARGUMENT;
        }
        break;
      case kRequestContentLength:
        if (!read_int64(value, value_length, &content_length)) {
          result = CURLE_BAD_FUNCTION_ARGUMENT;
        }
        break;
      default:
        break;
    }
    if (result != CURLE_OK) break;
  }
  if (result == CURLE_OK && (status != 0 || method == NULL || url == NULL)) {
    result = CURLE_BAD_FUNCTION_ARGUMENT;
  }
  if (result != CURLE_OK) goto done;

  request->follow_redirects = (flags & kRequestFlagFollowRedirects) != 0;
  request->has_body = (flags & kRequestFlagHasBody) != 0;
  const bool is_head = strcmp(method, "HEAD") == 0;
  if (is_head) request->has_body = false;

  request->easy = curl_easy_init();
  if (request->easy == NULL) {
    result = CURLE_FAILED_INIT;
    goto done;
  }

#define SET(option, value)                                    \
  do {                                                        \
    result = curl_easy_setopt(request->easy, option, value);  \
    if (result != CURLE_OK) goto done;                        \
  } while (0)

  SET(CURLOPT_URL, url);
  SET(CURLOPT_PRIVATE, request);
  SET(CURLOPT_ERRORBUFFER, request->error);
  SET(CURLOPT_NOSIGNAL, 1L);
  SET(CURLOPT_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_HEADERFUNCTION, header_callback);
  SET(CURLOPT_HEADERDATA, request);
  SET(CURLOPT_WRITEFUNCTION, write_callback);
  SET(CURLOPT_WRITEDATA, request);
  // Don't let libcurl send CONNECT responses from proxies to the header
  // callback.
  SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  if (request->follow_redirects) {
    // Like browsers, switch to GET for 303 responses, and for POST requests
    // that receive 301 or 302 responses, even with a custom method.
    SET(CURLOPT_FOLLOWLOCATION, (long)CURLFOLLOW_OBEYCODE);
    SET(CURLOPT_MAXREDIRS, (long)(max_redirects < 0 ? 0 : max_redirects));
  }
  if (config->http_version != CURL_HTTP_VERSION_NONE) {
    SET(CURLOPT_HTTP_VERSION, config->http_version);
  }
  if (config->http_version != CURL_HTTP_VERSION_1_0 &&
      config->http_version != CURL_HTTP_VERSION_1_1) {
    // Wait for a new connection to find out if it supports multiplexing
    // before opening more connections.
    SET(CURLOPT_PIPEWAIT, 1L);
  }
  if (config->buffer_size > 0) SET(CURLOPT_BUFFERSIZE, config->buffer_size);
  if (config->connect_timeout_ms > 0) {
    SET(CURLOPT_CONNECTTIMEOUT_MS, config->connect_timeout_ms);
  }
  if (config->user_agent != NULL) SET(CURLOPT_USERAGENT, config->user_agent);
  // Without a configured proxy, libcurl uses the proxy settings in the
  // environment (e.g. https_proxy and no_proxy), like dart:io's HttpClient. An
  // empty proxy disables the use of a proxy.
  if (config->proxy != NULL) SET(CURLOPT_PROXY, config->proxy);
  if (config->no_proxy != NULL) SET(CURLOPT_NOPROXY, config->no_proxy);
  if (config->verbose) SET(CURLOPT_VERBOSE, 1L);
  result = configure_tls(request, config);
  if (result != CURLE_OK) goto done;

  if (is_head) {
    SET(CURLOPT_NOBODY, 1L);
  } else if (request->has_body) {
    SET(CURLOPT_POST, 1L);
    SET(CURLOPT_READFUNCTION, read_callback);
    SET(CURLOPT_READDATA, request);
    SET(CURLOPT_SEEKFUNCTION, seek_callback);
    SET(CURLOPT_SEEKDATA, request);
    SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)content_length);
    if (config->buffer_size > 0) {
      long upload_buffer_size = config->buffer_size;
      if (upload_buffer_size > CURL_MAX_READ_SIZE) {
        upload_buffer_size = CURL_MAX_READ_SIZE;
      }
      SET(CURLOPT_UPLOAD_BUFFERSIZE, upload_buffer_size);
    }
    if (strcmp(method, "POST") != 0) SET(CURLOPT_CUSTOMREQUEST, method);
    // Without a Content-Type header, libcurl would send
    // "Content-Type: application/x-www-form-urlencoded" for POST requests.
    if (!has_content_type && !append_header(&request->headers, "Content-Type:")) {
      result = CURLE_OUT_OF_MEMORY;
      goto done;
    }
    // Don't send "Expect: 100-continue", which delays large requests.
    if (!has_expect && !append_header(&request->headers, "Expect:")) {
      result = CURLE_OUT_OF_MEMORY;
      goto done;
    }
  } else if (strcmp(method, "GET") != 0) {
    SET(CURLOPT_CUSTOMREQUEST, method);
  }
  if ((flags & kRequestFlagCloseConnection) != 0) {
    SET(CURLOPT_FORBID_REUSE, 1L);
  }
  if (request->headers != NULL) SET(CURLOPT_HTTPHEADER, request->headers);

#undef SET

done:
  free(method);
  free(url);
  return result;
}

#undef SET_OPTION

//
// The worker thread.
//

static void start_request(CurlHttpClient* client, Command* command) {
  if (find_request(client, command->request_id) != NULL) return;
  Request* request = (Request*)calloc(1, sizeof(Request));
  if (request == NULL) return;
  count_object(kCurlHttpObjectRequests, 1);
  request->client = client;
  request->id = command->request_id;
  request->body_rewindable = true;
  request->next = client->requests;
  if (client->requests != NULL) client->requests->previous = request;
  client->requests = request;

  CURLcode result = configure_request(request, &client->config, command->data,
                                      command->length);
  if (result != CURLE_OK) {
    request_fail(request, result, NULL);
    return;
  }
  const CURLMcode multi_result = curl_multi_add_handle(client->multi,
                                                       request->easy);
  if (multi_result != CURLM_OK) {
    request_fail(request, CURLE_FAILED_INIT, curl_multi_strerror(multi_result));
    return;
  }
  request->in_multi = true;
}

static void unpause_send(Request* request) {
  if (!request->send_paused) return;
  request->send_paused = false;
  if (request->in_multi) curl_easy_pause(request->easy, pause_bits(request));
}

// Processes the commands and returns true if the worker thread should exit.
static bool process_commands(CurlHttpClient* client, Command* command) {
  bool shutdown = false;
  while (command != NULL) {
    Command* next = command->next;
    command->next = NULL;
    Request* request = command->type == kCommandStart ||
                               command->type == kCommandShutdown
                           ? NULL
                           : find_request(client, command->request_id);
    switch (command->type) {
      case kCommandStart:
        if (!shutdown && !client->orphaned) start_request(client, command);
        command_free(command);
        break;
      case kCommandBody:
        if (request != NULL && !request->done && request->has_body &&
            !request->body_ended) {
          // The command becomes a chunk of the request body.
          if (request->body_last != NULL) {
            request->body_last->next = command;
          } else {
            request->body_first = command;
          }
          request->body_last = command;
          if (request->body_read == NULL) request->body_read = command;
          unpause_send(request);
        } else {
          command_free(command);
        }
        break;
      case kCommandEndBody:
        if (request != NULL && !request->done) {
          request->body_ended = true;
          request->body_failed = command->value != 0;
          unpause_send(request);
        }
        command_free(command);
        break;
      case kCommandAcknowledge:
        if (request != NULL) {
          request->unacknowledged -= command->value;
          if (request->unacknowledged < 0) request->unacknowledged = 0;
          if (request->receive_paused &&
              request->unacknowledged <= client->config.receive_window / 2) {
            request->receive_paused = false;
            if (request->in_multi) {
              curl_easy_pause(request->easy, pause_bits(request));
            }
          }
        }
        command_free(command);
        break;
      case kCommandCancel:
        if (request != NULL) request_destroy(request);
        command_free(command);
        break;
      case kCommandShutdown:
        shutdown = true;
        command_free(command);
        break;
    }
    command = next;
  }
  return shutdown;
}

static Command* take_commands(CurlHttpClient* client) {
  mutex_lock(&client->mutex);
  Command* commands = client->queue_head;
  client->queue_head = NULL;
  client->queue_tail = NULL;
  client->wakeup_pending = false;
  mutex_unlock(&client->mutex);
  return commands;
}

static void process_completed_transfers(CurlHttpClient* client) {
  CURLMsg* message;
  int remaining;
  while ((message = curl_multi_info_read(client->multi, &remaining)) != NULL) {
    if (message->msg != CURLMSG_DONE) continue;
    CURL* easy = message->easy_handle;
    CURLcode result = message->data.result;
    Request* request = NULL;
    curl_easy_getinfo(easy, CURLINFO_PRIVATE, (char**)&request);
    if (request == NULL) continue;
    curl_multi_remove_handle(client->multi, easy);
    request->in_multi = false;
    if (result == CURLE_OK && !request->headers_final) {
      if (request->header_lines.length > 0) {
        finalize_headers(request);
      } else {
        result = CURLE_GOT_NOTHING;
      }
    }
    request->done = true;
    request->result = result;
    mark_dirty(request);
  }
}

static void client_free(CurlHttpClient* client) {
  config_free(&client->config);
  mutex_destroy(&client->mutex);
  free(client);
  count_object(kCurlHttpObjectClients, -1);
}

static WORKER_RETURN_TYPE worker_main(void* argument) {
  CurlHttpClient* client = (CurlHttpClient*)argument;
#if defined(__APPLE__)
  pthread_setname_np("curl_http");
#elif defined(__linux__) && !defined(__ANDROID__)
  pthread_setname_np(pthread_self(), "curl_http");
#endif

  for (;;) {
    if (process_commands(client, take_commands(client))) break;
    if (client->requests != NULL) {
      int running = 0;
      curl_multi_perform(client->multi, &running);
      process_completed_transfers(client);
      flush_updates(client);
    }
    // Wait for network activity, a timeout or a command (curl_multi_wakeup).
    curl_multi_poll(client->multi, NULL, 0, client->requests != NULL ? 1000 : 60000,
                    NULL);
  }

  // Stop accepting commands before the multi handle is destroyed, since
  // enqueuing a command calls curl_multi_wakeup.
  mutex_lock(&client->mutex);
  client->worker_exiting = true;
  Command* remaining = client->queue_head;
  client->queue_head = NULL;
  client->queue_tail = NULL;
  mutex_unlock(&client->mutex);
  command_list_free(remaining);

  client->dirty = NULL;
  cancel_all_requests(client);
  curl_multi_cleanup(client->multi);
  client->multi = NULL;
  client_free(client);
  count_object(kCurlHttpObjectThreads, -1);
  return WORKER_RETURN_VALUE;
}

static int32_t enqueue(CurlHttpClient* client, Command* command) {
  if (command == NULL) return kCurlHttpOutOfMemory;
  mutex_lock(&client->mutex);
  if (client->worker_exiting) {
    mutex_unlock(&client->mutex);
    command_free(command);
    return kCurlHttpClosed;
  }
  if (client->queue_tail != NULL) {
    client->queue_tail->next = command;
  } else {
    client->queue_head = command;
  }
  client->queue_tail = command;
  if (!client->wakeup_pending) {
    client->wakeup_pending = true;
    // Called with the mutex held so that the worker thread can't destroy the
    // multi handle concurrently.
    curl_multi_wakeup(client->multi);
  }
  mutex_unlock(&client->mutex);
  return kCurlHttpOk;
}

//
// Public functions.
//

int32_t curl_http_initialize(Dart_PostCObject_Type post_cobject,
                             int64_t dart_api_major_version) {
  if (post_cobject == NULL ||
      dart_api_major_version != CURL_HTTP_DART_API_DL_MAJOR_VERSION) {
    return kCurlHttpInitializationFailed;
  }
  int32_t result = kCurlHttpOk;
  mutex_lock(&g_initialize_mutex);
  if (!g_initialized) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK) {
      g_initialized = true;
    } else {
      result = kCurlHttpInitializationFailed;
    }
  }
  if (result == kCurlHttpOk) g_post_cobject = post_cobject;
  mutex_unlock(&g_initialize_mutex);
  return result;
}

const char* curl_http_version(void) { return curl_version(); }

const char* curl_http_strerror(int32_t code) {
  return curl_easy_strerror((CURLcode)code);
}

CurlHttpClient* curl_http_client_create(Dart_Port port, const uint8_t* config,
                                        int64_t config_length) {
  if (!g_initialized) return NULL;
  CurlHttpClient* client = (CurlHttpClient*)calloc(1, sizeof(CurlHttpClient));
  if (client == NULL) return NULL;
  count_object(kCurlHttpObjectClients, 1);
  client->port = port;
  mutex_init(&client->mutex);
  if (!config_parse(&client->config, config, config_length)) {
    client_free(client);
    return NULL;
  }
  client->multi = curl_multi_init();
  if (client->multi == NULL) {
    client_free(client);
    return NULL;
  }
  if (client->config.max_connections_per_host > 0) {
    curl_multi_setopt(client->multi, CURLMOPT_MAX_HOST_CONNECTIONS,
                      client->config.max_connections_per_host);
  }
  if (client->config.max_connections > 0) {
    curl_multi_setopt(client->multi, CURLMOPT_MAX_TOTAL_CONNECTIONS,
                      client->config.max_connections);
  }
  count_object(kCurlHttpObjectThreads, 1);
  if (!thread_start(worker_main, client)) {
    count_object(kCurlHttpObjectThreads, -1);
    curl_multi_cleanup(client->multi);
    client_free(client);
    return NULL;
  }
  return client;
}

void curl_http_client_release(CurlHttpClient* client) {
  if (client == NULL) return;
  // If memory can't be allocated, the worker thread (and the client) leak.
  enqueue(client, command_new(kCommandShutdown, 0, 0, NULL, 0));
}

int32_t curl_http_client_start_request(CurlHttpClient* client,
                                       int64_t request_id, const uint8_t* spec,
                                       int64_t spec_length) {
  if (client == NULL || spec_length < 0 || (spec_length > 0 && spec == NULL)) {
    return kCurlHttpInvalidArgument;
  }
  return enqueue(client, command_new(kCommandStart, request_id, 0, spec,
                                     (size_t)spec_length));
}

int32_t curl_http_client_send_body(CurlHttpClient* client, int64_t request_id,
                                   const uint8_t* data, int64_t length) {
  if (client == NULL || length < 0 || (length > 0 && data == NULL)) {
    return kCurlHttpInvalidArgument;
  }
  if (length == 0) return kCurlHttpOk;
  return enqueue(client, command_new(kCommandBody, request_id, 0, data,
                                     (size_t)length));
}

int32_t curl_http_client_end_body(CurlHttpClient* client, int64_t request_id,
                                  int32_t error) {
  if (client == NULL) return kCurlHttpInvalidArgument;
  return enqueue(client,
                 command_new(kCommandEndBody, request_id, error, NULL, 0));
}

int32_t curl_http_client_acknowledge(CurlHttpClient* client, int64_t request_id,
                                     int64_t length) {
  if (client == NULL || length < 0) return kCurlHttpInvalidArgument;
  return enqueue(client,
                 command_new(kCommandAcknowledge, request_id, length, NULL, 0));
}

int32_t curl_http_client_cancel_request(CurlHttpClient* client,
                                        int64_t request_id) {
  if (client == NULL) return kCurlHttpInvalidArgument;
  return enqueue(client, command_new(kCommandCancel, request_id, 0, NULL, 0));
}

int64_t curl_http_live_object_count(int32_t kind) {
  if (kind < 0 || kind >= (int32_t)(sizeof(g_live_objects) /
                                    sizeof(g_live_objects[0]))) {
    return -1;
  }
  return atomic_load(&g_live_objects[kind]);
}
