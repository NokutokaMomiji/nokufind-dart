import 'dart:async';

import 'package:nokufind/nokufind.dart';

class SearchStatus {
    final String client;
    final List<Post> posts;
    
    SearchStatus({required this.client, required this.posts});
}

class SearchResult {
    final Finder finder;
    final String? client;

    final Future<List<Post>> future;   
    final Stream<SearchStatus> stream;
    final Future<dynamic> Function() cancel;

    final String tags;
    final String? optionalTags;
    final String? blacklist;

    final int page;

    final List<Post> _results = [];
    int _maxProgress = 0;
    int _progress = 0;
    final Stopwatch _stopwatch = Stopwatch();

    SearchResult({
        required this.finder,
        this.client,
        required this.future,
        required this.stream,
        required this.cancel,
        required this.tags,
        this.optionalTags,
        this.blacklist,
        required this.page
    }) {
        _stopwatch.start();

        _maxProgress = (client != null) ? 1 : finder.enabledClients.length;

        future.then((result) {
            _stopwatch.stop();
            _results.clear();
            _results.addAll(result);
        });

        stream.listen((data) {
            _progress++;
        });
    }

    List<Post> get results => List.unmodifiable(_results);
    double get progress => _progress / _maxProgress;
    int get progressPercentage => (progress * 100).floor();
    Duration get time => _stopwatch.elapsed;
}