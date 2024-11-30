import 'dart:async';
import 'dart:core';

import 'package:async/async.dart';
import 'package:executor/executor.dart';
import 'package:nokufind/src/Utils/download_stream.dart';

import 'Subfinder/subfinder.dart';
import 'Subfinder/danbooru_finder.dart';
import 'Subfinder/rule34_finder.dart';
import 'Subfinder/konachan_finder.dart';
import 'Subfinder/yandere_finder.dart';
import 'Subfinder/gelbooru_finder.dart';
import 'Subfinder/safebooru_finder.dart';

import 'post.dart';
import 'comment.dart';
import 'note.dart';
import 'Utils/utils.dart';

class NoSuchSubfinderException implements Exception {
    String cause;
    Iterable<String> names;
    NoSuchSubfinderException(this.cause, this.names);

    @override
    String toString() => "No Subfinder with name \"$cause\" found. Valid Subfinders are: ${names.join(', ')}";
}

class DisabledSubfinderException implements Exception {
    String cause;
    DisabledSubfinderException(this.cause);

    @override
    String toString() => "The specified subfinder \"$cause\" is disabled.";
}

class Finder {
    final Map<String, ISubfinder> _clients = {};
    final List<CancelableCompleter> _completers = [];

    late final SubfinderConfiguration _config;
    
    Finder() {
        _config = SubfinderConfiguration(callback: _onConfigChange);
        _config.setProperty("aliases", {});
        _config.setProperty("enabled", {});
        _config.setProperty("use_lower_quality", false);
        _config.lockProperties();
    }

    void addSubfinder(String name, ISubfinder subfinder) {
        _clients[name] = subfinder;
        _config.getConfig("aliases")[name] = {};
        _config.getConfig("enabled")[name] = true;
    }

    void removeSubfinder(String name) {
        (_config.getConfig("aliases") as Map).remove(name);
        (_config.getConfig("enabled") as Map).remove(name);
        _clients.remove(name);
    }

    ISubfinder? getSubfinder(String name) {
        return _clients[name];
    }

    bool hasSubfinder(String name) {
        return _clients.containsKey(name);
    }

    void addDefault() {
        addSubfinder("danbooru", DanbooruFinder());
        addSubfinder("rule34", Rule34Finder());
        addSubfinder("konachan", KonachanFinder());
        addSubfinder("yande.re", YandereFinder());
        addSubfinder("gelbooru", GelbooruFinder());
        addSubfinder("safebooru", SafebooruFinder());
    }

    void setTagAlias(String tag, String alias, String client) {
        _checkSubfinderExists(client);

        var aliases = configuration.getConfig("aliases") as Map;

        if (!aliases.containsKey(client)) {
            aliases[client] = {};
        }

        aliases[client][tag] = alias;
    }

    Map<String, String> getTagAliases(String client) {
        _checkSubfinderExists(client);
        
        var aliases = configuration.getConfig("aliases") as Map;

        if (!aliases.containsKey(client)) {
            aliases[client] = <String, String>{};
        }

        return Map<String, String>.from(aliases[client]);
    }

    void removeTagAlias(String tag, String client) {
        _checkSubfinderExists(client);

        var aliases = configuration.getConfig<Map>("aliases")!;

        if (!aliases.containsKey(client)) {
            aliases[client] = <String, String>{};
        }

        Nokulog.d(aliases[client].remove(tag));
    }

    bool subfinderIsEnabled(String client) {
        _checkSubfinderExists(client);

        return _config.getConfig<Map>("enabled")![client];
    }

    bool subfinderSetEnabled(String client, bool enabled) {
        _checkSubfinderExists(client);

        return _config.getConfig<Map>("enabled")![client] = enabled;
    }

    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page, String? client, bool cancelPreviousSearch = false}) async {
        if (cancelPreviousSearch) {
            await cancelSearch();
        }

        if (client != null) {
            _checkSubfinderExists(client);

            final bool isEnabled = _config.getConfig<Map>("enabled")![client]!;

            if (!isEnabled) {
                throw DisabledSubfinderException("Subfinder \"$client\" was selected but is disabled.");
            }

            var resultTags = _replaceAliases(tags, client);

            var posts = await (_clients[client] as ISubfinder).searchPosts(resultTags, limit: limit, page: page);
            
            if (posts.isEmpty) {
                Nokulog.d("[nokufind.Finder]: $client returned no posts.");
            }
            
            return posts;
        }

        Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(10));

        CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                executor.close();

                for (var client in _clients.entries) {
                    final bool isEnabled = _config.getConfig<Map>("enabled")![client.key]!;

                    if (!isEnabled) continue;

                    client.value.cancelLastSearch();
                }
            }
        );

        var searchFuture = _multipleFinderSearch(tags, completer, executor, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    Future<List<Post>> _multipleFinderSearch(String tags, CancelableCompleter completer, Executor executor, {int limit = 100, int? page}) async {
        if (completer.isCanceled) return [];

        List<Post> allPosts = [];

        for (var client in _clients.entries) {
            if (completer.isCanceled) return [];

            try {
                final bool isEnabled = _config.getConfig<Map>("enabled")![client.key]!;

                if (!isEnabled) {
                    Nokulog.d("Subfinder \"${client.key}\" is disabled. Skipping.");
                    continue;
                }
                
                executor.scheduleTask(() async {
                    if (completer.isCanceled) return;

                    var clientName = client.key;
                    var clientSubfinder = client.value;
                    
                    var resultTags = _replaceAliases(tags, clientName);

                    try {
                        var posts = await clientSubfinder.searchPosts(resultTags, limit: limit, page: page);
                        if (completer.isCanceled) return;
                        
                        if (posts.isEmpty) {
                            Nokulog.w("[nokufind.Finder] $clientName returned no posts.");
                        }
                        
                        allPosts.addAll(posts);
                        return;
                    } catch (e, stackTrace) {
                        Nokulog.e("[nokufind.Finder]: ($clientName) $e", error: e, stackTrace: stackTrace);
                        return;
                    }
                });
            } catch (e, stackTrace) {
                Nokulog.e("[nokufind.Finder]: An error occurred when attempting to schedule a task.", error: e, stackTrace: stackTrace);
            }
        }

        await executor.join(withWaiting: true);

        if (completer.isCanceled) return [];

        return allPosts;
    }

    String _replaceAliases(String tags, String client) {
        final aliases = configuration.getConfig("aliases") as Map;
        final clientAliases = Map<String, String>.from(aliases[client]);

        //print(clientAliases);

        List<String> splitTags = parseTagsWithQuotes(tags, includeQuotes: true);

        //Nokulog.d("Before ($client): $splitTags");

        for (int i = 0; i < splitTags.length; i++) {
            final String current = splitTags[i];

            final bool hasQuotes = (current.startsWith('"') || current.endsWith('"'));
            final String tag = trim(current, '"');

            //print("tag ($client): $tag");
            if (clientAliases.containsKey(tag)) {
                var alias = clientAliases[tag]!;
                splitTags[i] = (hasQuotes) ? "\"$alias\"" : alias;
            }
        }

        //okulog.d("After ($client): $splitTags");

        return splitTags.join(" ");
    }

    Future<void> cancelSearch() async {
        if (_completers.isEmpty) return;

        var lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }

    Future<Post?> getPost(int postID, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await _clients[client]?.getPost(postID);
        }

        for (var subfinder in _clients.values) {
            var post = await subfinder.getPost(postID);

            if (post != null) return post;
        }

        return null;
    }

    Future<List<Comment>> searchComments({String? client, int? postID, int limit = 100, int? page}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).searchComments(postID: postID, limit: limit, page: page);
        }

        List<Comment> allComments = [];

        for (var subfinder in _clients.values) {
            var comments = await subfinder.searchComments(postID: postID, limit: limit, page: page);
            allComments.addAll(comments);
        }

        return allComments;
    }

    Future<Comment?> getComment(int commentID, {int? postID, String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await _clients[client]?.getComment(commentID, postID: postID);
        }

        for (var subfinder in _clients.values) {
            var comment = await subfinder.getComment(commentID, postID: postID);
            if (comment != null) return comment;
        }

        return null;
    }

    Future<List<Note>> getNotes(int postID, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).getNotes(postID);
        }

        List<Note> allNotes = [];

        for (var subfinder in _clients.values) {
            var notes = await subfinder.getNotes(postID);

            allNotes.addAll(notes);
        }

        return allNotes;
    }

    Future<Post?> postGetParent(Post post, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return (_clients[client])?.postGetParent(post);
        }

        if (_clients.containsKey(post.source)) {
            return (_clients[post.source])?.postGetParent(post);
        }

        for (var subfinder in _clients.values) {
            var parentPost = await subfinder.postGetParent(post);
            if (parentPost != null) return parentPost;
        }

        return null;
    }

    Future<List<Post>> postGetChildren(Post post, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).postGetChildren(post);
        }

        if (_clients.containsKey(post.source)) {
            return (_clients[post.source] as ISubfinder).postGetChildren(post);
        }

        for (var subfinder in _clients.values) {
            var childrenPosts = await subfinder.postGetChildren(post);
            if (childrenPosts.isNotEmpty) return childrenPosts;
        }

        return List<Post>.empty(growable: true);
    }

    Future<List<String?>> downloadFast(List<Post> posts, String path) async {
        Executor executor = Executor(concurrency: 7);
        List<String?> savePaths = [];

        final List<Post> randomizedPosts = List<Post>.from(posts);
        randomizedPosts.shuffle();

        for (var post in randomizedPosts) {
            executor.scheduleTask(() async {
                try {
                    savePaths.addAll(await post.downloadAll(path));
                } catch (e, stackTrace) {
                    Nokulog.e("Failed to download files for post ${post.identifier}", error: e, stackTrace: stackTrace);
                }
            });
	    }

        await executor.join(withWaiting: true);
        await executor.close();

        return savePaths;
    }

    Future<void> fetchData(List<Post> posts, {bool onlyMainImage = false}) async {
        if (posts.isEmpty) {
            Nokulog.d("> [nokufind.Finder]: Post list was empty. Exiting.");
            return;   
        }
        
        Executor executor = Executor(concurrency: 15);

        for (var post in posts) {
            executor.scheduleTask(() async {
                try {
                    Nokulog.d("Fetching ${post.identifier}...");
                    await post.fetchData(onlyMainImage: onlyMainImage);
                } catch (e) {
                    Nokulog.d("[nokufind.Finder]: (${post.identifier}) $e");
                    return List<Post>.empty();
                }
            });
        }

        await executor.join(withWaiting: true);
        await executor.close();
    }

    DownloadStream fetchDataStream(List<Post> posts, {FutureOr<void> Function(Post post)? onFetched, FutureOr<void> Function()? onFinished}) {
        var obj = DownloadStream(posts);

        if (onFetched != null) {
            obj.start(onFetched, onFinished: onFinished);
        }

        return obj;
    }

    List<Post> filterByMD5(List<Post> posts, {bool generateMD5 = false}) {
        List<String> md5Hashes = [];

        bool innerFilter(Post post) {
            if (post.md5.isEmpty && !generateMD5) return true;

            if (md5Hashes.contains(post.md5[0])) return false;

            md5Hashes.add(post.md5[0]);
            return true;
        }

        return posts.where((element) => innerFilter(element)).toList();
    }

    void _onConfigChange(String key, dynamic value, bool isCookie, bool isHeader) {
        for (var subfinder in _clients.values) {
            if (isCookie) {
                subfinder.configuration.setCookie(key, value.toString());
                continue;
            }

            if (isHeader) {
                subfinder.configuration.setHeader(key, value.toString());
                continue;
            }

            try {
                subfinder.configuration.setConfig(key, value);
            } catch (e) {
                continue;
            }
        }
    }

    void _checkSubfinderExists(String name) {
        if (!_clients.containsKey(name)) {
            throw NoSuchSubfinderException(name, _clients.keys);
        }
    }

    SubfinderConfiguration get configuration => _config;
    List<String> get clientNames => _clients.keys.toList();
    List<String> get enabledClients => _clients.keys.where((client) => subfinderIsEnabled(client)).toList();
}

