// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds libcurl, and the libraries that it depends on, from the sources in
/// `third_party/` and links them, together with `src/curl_http.c`, into a
/// single dynamic library.
///
/// The build has three steps:
///
/// 1. `src/deps/CMakeLists.txt` builds BoringSSL and nghttp2 as static
///    libraries.
/// 2. libcurl's own CMake build compiles it as a static library. It runs after
///    the first step because it compiles and links test programs against
///    BoringSSL and nghttp2 to detect their features.
/// 3. [CBuilder] compiles `src/curl_http.c` and links it with the static
///    libraries into the `package:curl_http/curl_http.dart` code asset.
///
/// The CMake build directories are kept in the hook's output directory so that
/// later builds are incremental.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final logger = Logger('')
      ..level = Level.ALL
      ..onRecord.listen((record) => print(record.message));

    final packageRoot = input.packageRoot;
    final outputDirectory = input.outputDirectory;
    final code = input.config.code;
    final toolchain = _toolchainDefines(code);
    final cmake = _CMake(logger: logger);

    // Step 1: BoringSSL and nghttp2.
    final depsBuild = outputDirectory.resolve('deps-build/');
    final depsPrefix = outputDirectory.resolve('deps/');
    await cmake.build(
      source: packageRoot.resolve('src/deps/'),
      build: depsBuild,
      defines: {
        ...toolchain,
        'CMAKE_INSTALL_PREFIX': depsPrefix.toFilePath(),
        'CMAKE_INSTALL_LIBDIR': 'lib',
        'CMAKE_INSTALL_INCLUDEDIR': 'include',
      },
      install: true,
    );

    // Step 2: libcurl.
    final curlBuild = outputDirectory.resolve('curl-build/');
    await cmake.build(
      source: packageRoot.resolve('third_party/curl/'),
      build: curlBuild,
      defines: {...toolchain, ..._curlDefines(code, depsPrefix)},
    );

    // Step 3: the dynamic library.
    final libraryDirectories = [
      curlBuild.resolve('lib/').toFilePath(),
      depsPrefix.resolve('lib/').toFilePath(),
    ];
    final exportsFile = File.fromUri(outputDirectory.resolve('exports.txt'));
    await exportsFile.writeAsString(
      [for (final symbol in _exportedSymbols) '_$symbol', ''].join('\n'),
    );
    final versionScript = File.fromUri(outputDirectory.resolve('exports.map'));
    await versionScript.writeAsString(
      [
        '{',
        '  global:',
        for (final symbol in _exportedSymbols) '    $symbol;',
        '  local: *;',
        '};',
        '',
      ].join('\n'),
    );

    await CBuilder.library(
      name: 'curl_http',
      assetName: 'curl_http.dart',
      sources: [
        'src/curl_http.c',
        // Certificate verification with the Security framework.
        if (code.targetOS case OS.macOS || OS.iOS) 'src/apple_trust.c',
      ],
      includes: ['third_party/curl/include', 'third_party/boringssl/include'],
      defines: {'CURL_STATICLIB': null},
      std: 'c11',
      flags: [
        '-fvisibility=hidden',
        if (code.targetOS case OS.macOS || OS.iOS) ...[
          // Only export the functions declared in `src/curl_http.h`, so that
          // the unused parts of the static libraries can be removed.
          '-Wl,-exported_symbols_list,${exportsFile.path}',
          '-Wl,-dead_strip',
        ],
        if (code.targetOS case OS.linux || OS.android) ...[
          '-Wl,--version-script=${versionScript.path}',
          '-Wl,--gc-sections',
          // Don't let the symbols of the static libraries (e.g. BoringSSL)
          // interpose, or be interposed by, symbols in other libraries.
          '-Wl,--exclude-libs,ALL',
          '-Wl,-Bsymbolic',
        ],
      ],
      libraries: [
        'curl',
        'nghttp2',
        'ssl',
        'crypto',
        // BoringSSL's libssl is written in C++.
        if (code.targetOS case OS.macOS || OS.iOS) 'c++',
        if (code.targetOS case OS.linux) ...['stdc++', 'pthread'],
        if (code.targetOS case OS.android) ...['c++_static', 'c++abi'],
        if (code.targetOS case OS.windows) ...[
          'ws2_32',
          'crypt32',
          'bcrypt',
          'iphlpapi',
          'secur32',
          'advapi32',
          'user32',
        ],
      ],
      libraryDirectories: libraryDirectories,
      frameworks: [
        if (code.targetOS case OS.macOS || OS.iOS) ...[
          'CoreFoundation',
          'Security',
          'SystemConfiguration',
        ],
      ],
    ).run(input: input, output: output, logger: logger);

    output.dependencies.addAll(_dependencies(packageRoot));
  });
}

/// The functions declared in `src/curl_http.h`.
const _exportedSymbols = [
  'curl_http_initialize',
  'curl_http_version',
  'curl_http_strerror',
  'curl_http_client_create',
  'curl_http_client_release',
  'curl_http_client_start_request',
  'curl_http_client_send_body',
  'curl_http_client_end_body',
  'curl_http_client_acknowledge',
  'curl_http_client_cancel_request',
  'curl_http_live_object_count',
];

/// The CMake cache variables that configure libcurl's build.
Map<String, String> _curlDefines(CodeConfig code, Uri depsPrefix) {
  final include = depsPrefix.resolve('include').toFilePath();
  final lib = depsPrefix.resolve('lib/');
  String library(String name) =>
      lib.resolve(code.targetOS.staticlibFileName(name)).toFilePath();
  final isApple = code.targetOS == OS.macOS || code.targetOS == OS.iOS;

  return {
    'BUILD_SHARED_LIBS': 'OFF',
    'BUILD_STATIC_LIBS': 'ON',
    'BUILD_CURL_EXE': 'OFF',
    'BUILD_TESTING': 'OFF',
    'BUILD_EXAMPLES': 'OFF',
    'BUILD_LIBCURL_DOCS': 'OFF',
    'BUILD_MISC_DOCS': 'OFF',
    'ENABLE_CURL_MANUAL': 'OFF',
    // Perl is only needed for the documentation.
    'CMAKE_DISABLE_FIND_PACKAGE_Perl': 'ON',
    'CURL_DISABLE_INSTALL': 'ON',
    'CURL_ENABLE_EXPORT_TARGET': 'OFF',
    'CURL_HIDDEN_SYMBOLS': 'ON',
    'PICKY_COMPILER': 'OFF',
    // Only HTTP (and WebSockets) are needed.
    for (final protocol in const [
      'DICT',
      'FILE',
      'FTP',
      'GOPHER',
      'IMAP',
      'IPFS',
      'LDAP',
      'LDAPS',
      'MQTT',
      'POP3',
      'RTSP',
      'SMTP',
      'TELNET',
      'TFTP',
    ])
      'CURL_DISABLE_$protocol': 'ON',
    // Features that package:curl_http doesn't use.
    for (final feature in const [
      'AWS',
      'COOKIES',
      'DOH',
      'FORM_API',
      'HSTS',
      'KERBEROS_AUTH',
      'MIME',
      'NEGOTIATE_AUTH',
      'NETRC',
      'PROGRESS_METER',
    ])
      'CURL_DISABLE_$feature': 'ON',
    'CURL_ENABLE_NTLM': 'OFF',
    // Never pick up libraries installed on the build machine.
    'CURL_USE_PKGCONFIG': 'OFF',
    'CURL_ZLIB': 'OFF',
    'CURL_BROTLI': 'OFF',
    'CURL_ZSTD': 'OFF',
    'USE_LIBIDN2': 'OFF',
    'USE_APPLE_IDN': 'OFF',
    'CURL_USE_LIBPSL': 'OFF',
    'CURL_USE_LIBSSH2': 'OFF',
    'CURL_USE_LIBSSH': 'OFF',
    'CURL_USE_GSSAPI': 'OFF',
    'ENABLE_ARES': 'OFF',
    'ENABLE_THREADED_RESOLVER': 'ON',
    'ENABLE_UNIX_SOCKETS': 'OFF',
    // TLS with BoringSSL.
    'CURL_USE_OPENSSL': 'ON',
    if (code.targetOS == OS.windows) 'CURL_USE_SCHANNEL': 'OFF',
    'OPENSSL_ROOT_DIR': depsPrefix.toFilePath(),
    'OPENSSL_INCLUDE_DIR': include,
    'OPENSSL_SSL_LIBRARY': library('ssl'),
    'OPENSSL_CRYPTO_LIBRARY': library('crypto'),
    // Verify certificates with the operating system on Apple platforms. On
    // other platforms, `src/curl_http.c` locates the trusted certificates at
    // runtime.
    if (isApple) 'USE_APPLE_SECTRUST': 'ON',
    'CURL_CA_BUNDLE': 'none',
    'CURL_CA_PATH': 'none',
    'CURL_CA_FALLBACK': 'OFF',
    // HTTP/2 with nghttp2.
    'USE_NGHTTP2': 'ON',
    'NGHTTP2_INCLUDE_DIR': include,
    'NGHTTP2_LIBRARY': library('nghttp2'),
  };
}

/// The CMake cache variables that select the compiler and target.
Map<String, String> _toolchainDefines(CodeConfig code) {
  final defines = <String, String>{
    'CMAKE_BUILD_TYPE': 'Release',
    'CMAKE_POSITION_INDEPENDENT_CODE': 'ON',
    // Only `src/curl_http.c` exports symbols from the dynamic library.
    'CMAKE_C_VISIBILITY_PRESET': 'hidden',
    'CMAKE_CXX_VISIBILITY_PRESET': 'hidden',
  };

  final compiler = code.cCompiler;
  if (compiler != null && code.targetOS != OS.windows) {
    final cc = compiler.compiler.toFilePath();
    defines['CMAKE_C_COMPILER'] = cc;
    final cxx = cc.endsWith('clang')
        ? '$cc++'
        : cc.replaceFirst(RegExp(r'gcc$'), 'g++');
    if (File(cxx).existsSync()) defines['CMAKE_CXX_COMPILER'] = cxx;
    defines['CMAKE_AR'] = compiler.archiver.toFilePath();
  }

  final architecture = code.targetArchitecture;
  String appleArchitecture() => switch (architecture) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError(
      'package:curl_http does not support $architecture on ${code.targetOS}.',
    ),
  };

  switch (code.targetOS) {
    case OS.macOS:
      defines['CMAKE_OSX_ARCHITECTURES'] = appleArchitecture();
      defines['CMAKE_OSX_DEPLOYMENT_TARGET'] = '${code.macOS.targetVersion}';
    case OS.iOS:
      defines['CMAKE_SYSTEM_NAME'] = 'iOS';
      defines['CMAKE_OSX_SYSROOT'] = code.iOS.targetSdk == IOSSdk.iPhoneOS
          ? 'iphoneos'
          : 'iphonesimulator';
      defines['CMAKE_OSX_ARCHITECTURES'] = appleArchitecture();
      defines['CMAKE_OSX_DEPLOYMENT_TARGET'] = '${code.iOS.targetVersion}';
    case OS.android:
      if (compiler == null) {
        throw UnsupportedError(
          'Building package:curl_http for Android requires the Android NDK.',
        );
      }
      // The compiler is in `<ndk>/toolchains/llvm/prebuilt/<host>/bin/`.
      final ndk = compiler.compiler.resolve('../../../../../');
      defines['CMAKE_TOOLCHAIN_FILE'] = ndk
          .resolve('build/cmake/android.toolchain.cmake')
          .toFilePath();
      defines['ANDROID_ABI'] = switch (architecture) {
        Architecture.arm => 'armeabi-v7a',
        Architecture.arm64 => 'arm64-v8a',
        Architecture.ia32 => 'x86',
        Architecture.x64 => 'x86_64',
        _ => throw UnsupportedError(
          'package:curl_http does not support $architecture on Android.',
        ),
      };
      defines['ANDROID_PLATFORM'] = 'android-${code.android.targetNdkApi}';
    default:
      if (architecture != Architecture.current || code.targetOS != OS.current) {
        throw UnsupportedError(
          'package:curl_http does not support cross-compiling for '
          '${code.targetOS} $architecture.',
        );
      }
  }
  return defines;
}

/// Runs CMake builds.
class _CMake {
  final Logger logger;

  _CMake({required this.logger});

  /// Configures (if needed) and builds the CMake project in [source] in the
  /// [build] directory, and then installs it if [install] is true.
  Future<void> build({
    required Uri source,
    required Uri build,
    required Map<String, String> defines,
    bool install = false,
  }) async {
    final buildPath = build.toFilePath();
    await Directory(buildPath).create(recursive: true);
    // Reconfigure if the definitions change, e.g. after updating the package.
    final definesFile = File.fromUri(build.resolve('curl_http_defines.txt'));
    final definesText =
        (defines.entries.map((e) => '${e.key}=${e.value}').toList()..sort())
            .join('\n');
    final configured =
        File.fromUri(build.resolve('CMakeCache.txt')).existsSync() &&
        definesFile.existsSync() &&
        await definesFile.readAsString() == definesText;
    if (!configured) {
      await _run([
        '-S',
        source.toFilePath(),
        '-B',
        buildPath,
        '-G',
        _generator,
        for (final MapEntry(:key, :value) in defines.entries) '-D$key=$value',
      ]);
      await definesFile.writeAsString(definesText);
    }
    await _run([
      '--build',
      buildPath,
      '--config',
      'Release',
      '--parallel',
      '${Platform.numberOfProcessors}',
    ]);
    if (install) {
      await _run(['--install', buildPath, '--config', 'Release']);
    }
  }

  String get _generator =>
      Platform.isWindows ? 'Visual Studio 17 2022' : 'Unix Makefiles';

  Future<void> _run(List<String> arguments) async {
    logger.info('cmake ${arguments.join(' ')}');
    final result = await Process.run('cmake', arguments);
    final stdoutText = result.stdout as String;
    final stderrText = result.stderr as String;
    if (result.exitCode != 0) {
      final command = 'cmake ${arguments.join(' ')}';
      throw BuildError(
        message: [
          '$command failed with exit code ${result.exitCode}.',
          _tail(stdoutText),
          _tail(stderrText),
        ].join('\n'),
      );
    }
    logger.fine(_tail(stdoutText));
  }

  static String _tail(String text, {int lines = 60}) {
    final split = text.trimRight().split('\n');
    return split.length <= lines
        ? split.join('\n')
        : split.sublist(split.length - lines).join('\n');
  }
}

/// The files that, when changed, require the hook to run again.
Iterable<Uri> _dependencies(Uri packageRoot) sync* {
  yield packageRoot.resolve('pubspec.yaml');
  for (final directory in ['src/', 'third_party/']) {
    final root = Directory.fromUri(packageRoot.resolve(directory));
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is File) yield entity.uri;
    }
  }
}
