import 'dart:async';

import 'package:http/http.dart';
import 'dart:math';

Future<double> runMany(Future<double> Function() fn) async {
  var l = double.maxFinite;

  for (var i = 0; i < 100; ++i) {
    l = min(l, await fn());
  }
  return l;
}

Future<double> testN(Client Function() clientFn, int i) async {
  final client = clientFn();

  final stopwatch = Stopwatch()..start();
  for (var j = 1; j <= i; ++j) {
    final url = Uri.http(
        'localhost:8080', '/${Random().nextInt(10000)}'); // 10.0.2.2:8080
    await client.read(url);
  }
  stopwatch.stop();
  client.close();
  return stopwatch.elapsed.inMicroseconds * 1e-6;
}

Future<void> doNetworkThing(Client client) async {
  final url = Uri.parse(
      'https://helloworld-taiwan-b6avxfvuma-de.a.run.app/${Random().nextInt(10000)}');
  // 'http://127.0.0.1:8080');
//        'https://effigis.com/wp-content/uploads/2015/02/Airbus_Pleiades_50cm_8bit_RGB_Yogyakarta.jpg');
//        "https://lh3.googleusercontent.com/cOF3LzLFCJA_H4umxV5kNRYSrWj9HvmL4L_snwvs7Pp8wFGf7j9m_y0OQXMxF_2wygJRz7UOwa13C_IywvfAU9cDL_aCQWuL3UsG_P_9Yac0j_Ey0nbFiaqSh7Y7kB4TqxQn7fLFAlmktcrUdfgrKosIhktieNCldkOcMJE6x_7T7gZ0TVEJePIBX724p9cJutuw6vKue6SGmgttN-ZYD0W6ezzQfuq_yNXVCiTMm1685vLIBCDap4riHNi6K9P3JOyg9C_Ua1bxGkcncVCqQsbVYWWpT-lKy6a-NqnxAi-Mnyw9IbhA3u4Du-6CuZMlk_ZlIO7WnMDVm-bguOO_VfWvdwXojH_lJVeqQtKkItU4CzPlJZoqX_h-UquNFg6rniDaKvtWe13YAfw4AefMND3IqrcIiFT7rNCDY7QQ9BGUz3V2z4k9ErXn0eluPHOvC6FMd6EJe1nGVo6-AUTApRjFlF5gbaLduGLu9XrqljIHfPcPWMkCtVuPJLFhsXOb3vGlgrG5pJ_2OycNZB67wkvVAATAlXf6s7RK7NBcLjxBEbJKHS4eZyAJ1CtuzojRpNwkvvL26f08tu8U6wC9UPAC9MlXSr6oOTIqVA_N05KKC5Sk3-6Y_nuUcBtTl8KtQ5sSVO-smPFyap9mZvfpyC7d_b_xPO9EMzxgUZz39Nd9nNAZA6xuMjJxjOjegHWMamFeM4imV4pbR-x3Ts1grk2Y3auiaiSP-ILIkkiC_htd28GHBhiW=w1795-h1346-no?authuser=0");
  final response = await client.send(Request('GET', url));

  assert(response.statusCode == 200);
//    assert(response.statusCode == 404);
  await response.stream.drain();
}

Future<double> benchmark(Client Function() clientFn) async {
  final client = clientFn();
  final stopwatch = Stopwatch()..start();

//  await client.read(url);
  final futures = <Future<void>>[];
  for (var i = 0; i < 10; ++i) {
    futures.add(doNetworkThing(client));
  }
  await Future.wait(futures);
  stopwatch.stop();
  client.close();
  return stopwatch.elapsed.inMicroseconds * 1e-6;
}

Future<Map<String, double>> foo(Client Function() clientFn) async {
  final results = <double>[];
  final stopwatch = Stopwatch()..start();
  await benchmark(clientFn);
  while (stopwatch.elapsed < const Duration(seconds: 300)) {
    results.add(await benchmark(clientFn));
  }
  return {
    'min': results.fold<double>(double.maxFinite, min),
    'count': results.length.toDouble(),
    'median': results.fold<double>(0, (x, y) => x + y) / results.length
  };
}

Stream<Map<String, double>> benchmarkAll(Client Function() clientFn) {
  final sc = StreamController<Map<String, double>>();

  foo(clientFn).then((x) {
    sc
      ..add(x)
      ..close();
  });

//  sc.close();
  return sc.stream;
/*
  for (var i = 1; i <= 10; ++i) {
    print('$i => ${await runMany(() => testN(clientFn, i)) / i}');
  }
*/
  /*
  final url = Uri.http('localhost:8080', '');
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < 10; ++i) {
    await client.get(url);
  }
  stopwatch.stop();
  print(stopwatch.elapsed);
  */
}
