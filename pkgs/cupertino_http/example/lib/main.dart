// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_client.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http_client_conformance_tests/http_client_benchmarks.dart';

void main() {
  late Client client;
  if (Platform.isIOS) {
    client = CupertinoClient.defaultSessionConfiguration();
  } else {
    client = IOClient();
  }

  runWithClient(() => runApp(const BookSearchApp()), () => client);
}

class Book {
  String title;
  String description;
  String imageUrl;

  Book(this.title, this.description, this.imageUrl);
}

class BookSearchApp extends StatelessWidget {
  const BookSearchApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => const MaterialApp(
        // Remove the debug banner
        debugShowCheckedModeBanner: false,
        title: 'Book Search',
        home: HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Book> _books = [];

  @override
  void initState() {
    super.initState();
  }

  void _runSearch(String query) async {
    // docker run -d -p 8080:8080 -v $PWD/index.html:/usr/share/caddy/index.html -v caddy_data:/data -v $PWD/Caddyfile:/etc/caddy/Caddyfile caddy
    // python3 -m timeit --setup 'import urllib.request' 'urllib.request.urlopen("http://localhost:8080/f").read()'
    final config = URLSessionConfiguration.defaultSessionConfiguration();
//      ..requestCachePolicy = URLRequestCachePolicy.reloadIgnoringLocalCacheData;
    await benchmarkAll(() => CupertinoClient.fromSessionConfiguration(config))
        .listen((x) {
      setState(() {
        _books.add(Book("Cupertino", x.toString(),
            "http://sweetapp.com/images/britishflag.gif"));
      });
    }, onError: (e) => print).asFuture();

    await benchmarkAll(IOClient.new).listen((x) {
      setState(() {
        _books.add(Book(
            "IO", x.toString(), "http://sweetapp.com/images/britishflag.gif"));
      });
    }, onError: (e) => print).asFuture();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Book Search'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              const SizedBox(
                height: 20,
              ),
              TextField(
                onChanged: _runSearch,
                decoration: const InputDecoration(
                    labelText: 'Search', suffixIcon: Icon(Icons.search)),
              ),
              const SizedBox(
                height: 20,
              ),
              Expanded(
                child: _books.isNotEmpty
                    ? BookList(_books)
                    : const Text(
                        'No results found',
                        style: TextStyle(fontSize: 24),
                      ),
              ),
            ],
          ),
        ),
      );
}

class BookList extends StatefulWidget {
  final List<Book> books;
  const BookList(this.books, {Key? key}) : super(key: key);

  @override
  State<BookList> createState() => _BookListState();
}

class _BookListState extends State<BookList> {
  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: widget.books.length,
        itemBuilder: (context, index) => Card(
          key: ValueKey(widget.books[index].title),
          child: ListTile(
            leading: Image.network(widget.books[index].imageUrl),
            title: Text(widget.books[index].title),
            subtitle: Text(widget.books[index].description),
          ),
        ),
      );
}
