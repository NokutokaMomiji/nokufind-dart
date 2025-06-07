import 'dart:async';
import 'dart:core';

import 'package:async/async.dart';
import 'package:executor/executor.dart';
import 'package:nokufind/src/Utils/download_stream.dart';
import 'package:nokufind/src/description.dart';

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

    Duration timeout = const Duration(minutes: 1);

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
        _config.getConfig<Map>("aliases", defaultValue: {})[name] = {};
        _config.getConfig<Map>("enabled", defaultValue: {})[name] = true;
    }

    void removeSubfinder(String name) {
        (_config.getConfig("aliases", defaultValue: {})).remove(name);
        (_config.getConfig("enabled", defaultValue: {})).remove(name);
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

        final aliases = configuration.getConfig<Map>("aliases", defaultValue: {});

        if (!aliases.containsKey(client)) {
            aliases[client] = {};
        }

        aliases[client][tag] = alias;
    }

    Map<String, String> getTagAliases(String client) {
        _checkSubfinderExists(client);
        
        final aliases = configuration.getConfig<Map>("aliases", defaultValue: {});

        if (!aliases.containsKey(client)) {
            aliases[client] = <String, String>{};
        }

        return Map<String, String>.from(aliases[client]);
    }

    void removeTagAlias(String tag, String client) {
        _checkSubfinderExists(client);

        final aliases = configuration.getConfig<Map>("aliases", defaultValue: {});

        if (!aliases.containsKey(client)) {
            aliases[client] = <String, String>{};
        }

        Nokulog.d(aliases[client].remove(tag));
    }

    bool subfinderIsEnabled(String client) {
        _checkSubfinderExists(client);

        return _config.getConfig<Map?>("enabled", defaultValue: null)![client];
    }

    bool subfinderSetEnabled(String client, bool enabled) {
        _checkSubfinderExists(client);

        return _config.getConfig<Map?>("enabled", defaultValue: null)![client] = enabled;
    }

    Future<List<Post>> searchPosts(String tags, {int limit = 100, int page = 0, String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);

            final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client]!;

            if (!isEnabled) {
                throw DisabledSubfinderException("Subfinder \"$client\" was selected but is disabled.");
            }

            final resultTags = _replaceAliases(tags, client);

            final posts = await (_clients[client] as ISubfinder).searchPosts(resultTags, limit: limit, page: page);
            
            if (posts.isEmpty) {
                Nokulog.d("[nokufind.Finder]: $client returned no posts.");
            }
            
            return posts;
        }

        final Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(10));

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                executor.close();

                for (final client in _clients.entries) {
                    final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client.key]!;

                    if (!isEnabled) continue;

                    client.value.cancelLastSearch();
                }
            }
        );

        final searchFuture = _multipleFinderSearch(tags, completer, executor, limit: limit, page: page);

        searchFuture.then((posts) {
            Future.wait(posts.map<Future<void>>((element) => element.recheckTags()));
        });

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    Future<List<Post>> _multipleFinderSearch(String tags, CancelableCompleter completer, Executor executor, {int limit = 100, int? page}) async {
        if (completer.isCanceled) return [];

        final List<Post> allPosts = [];

        for (final client in _clients.entries) {
            if (completer.isCanceled) return [];

            try {
                final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client.key]!;

                if (!isEnabled) {
                    Nokulog.d("Subfinder \"${client.key}\" is disabled. Skipping.");
                    continue;
                }
                
                executor.scheduleTask(() async {
                    if (completer.isCanceled) return;

                    final clientName = client.key;
                    final clientSubfinder = client.value;
                    
                    final resultTags = _replaceAliases(tags, clientName);

                    try {
                        bool hasBeenCancelled = false;

                        final Timer timer = Timer(timeout, () {
                            clientSubfinder.cancelLastSearch();
                            hasBeenCancelled = true;
                        });
                        
                        final posts = await clientSubfinder.searchPosts(resultTags, limit: limit, page: page);

                        if (timer.isActive) {
                            timer.cancel();
                        }

                        if (completer.isCanceled || hasBeenCancelled) {
                            if (hasBeenCancelled) Nokulog.e("Subfinder \"$clientName\" timed out.");
                            return;
                        }
                        
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

    Future<List<Post>> searchPostsAdvanced(
        String tags,
        {
            String optionalTags = "",
            String blacklist = "",
            int limit = 100, 
            int page = 0, 
            String? client
        }) async {
        if (client != null) {
            _checkSubfinderExists(client);

            final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client]!;

            if (!isEnabled) {
                throw DisabledSubfinderException("Subfinder \"$client\" was selected but is disabled.");
            }

            final resultTags = _replaceAliases(tags, client);

            final posts = await (_clients[client] as ISubfinder).searchPostsAdvanced(
                resultTags, 
                optionalTags: optionalTags,
                blacklist: blacklist,
                limit: limit, 
                page: page
            );
            
            if (posts.isEmpty) {
                Nokulog.d("[nokufind.Finder]: $client returned no posts.");
            }
            
            return posts;
        }

        final Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(10));

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                executor.close();

                for (final client in _clients.entries) {
                    final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client.key]!;

                    if (!isEnabled) continue;

                    client.value.cancelLastSearch();
                }
            }
        );

        final searchFuture = _multipleFinderSearchAdvanced(
            tags, 
            completer, 
            executor, 
            optionalTags: optionalTags,
            blacklist: blacklist,
            limit: limit, 
            page: page
        );

        searchFuture.then((posts) {
            Future.wait(posts.map<Future<void>>((element) => element.recheckTags()));
        });

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    Future<List<Post>> _multipleFinderSearchAdvanced(
        String tags, 
        CancelableCompleter completer, 
        Executor executor, 
        {
            String optionalTags = "",
            String blacklist = "",
            int limit = 100, 
            int? page
        }) async {
        if (completer.isCanceled) return [];

        final List<Post> allPosts = [];

        for (final client in _clients.entries) {
            if (completer.isCanceled) return [];

            try {
                final bool isEnabled = _config.getConfig<Map?>("enabled", defaultValue: null)![client.key]!;

                if (!isEnabled) {
                    Nokulog.d("Subfinder \"${client.key}\" is disabled. Skipping.");
                    continue;
                }
                
                executor.scheduleTask(() async {
                    if (completer.isCanceled) return;

                    final clientName = client.key;
                    final clientSubfinder = client.value;
                    
                    final resultTags = _replaceAliases(tags, clientName);

                    try {
                        bool hasBeenCancelled = false;

                        final Timer timer = Timer(timeout, () {
                            clientSubfinder.cancelLastSearch();
                            hasBeenCancelled = true;
                        });
                        
                        final posts = await clientSubfinder.searchPostsAdvanced(
                            resultTags, 
                            optionalTags: optionalTags,
                            blacklist: blacklist,
                            limit: limit, 
                            page: page
                        );

                        if (timer.isActive) {
                            timer.cancel();
                        }

                        if (completer.isCanceled || hasBeenCancelled) {
                            if (hasBeenCancelled) Nokulog.e("Subfinder \"$clientName\" timed out.");
                            return;
                        }
                        
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
        final aliases = configuration.getConfig<Map>("aliases", defaultValue: {});
        final clientAliases = Map<String, String>.from(aliases[client]);

        //print(clientAliases);

        final List<String> splitTags = parseTagsWithQuotes(tags, includeQuotes: true);

        //Nokulog.d("Before ($client): $splitTags");

        for (int i = 0; i < splitTags.length; i++) {
            final String current = splitTags[i];

            final bool hasQuotes = (current.startsWith('"') || current.endsWith('"'));
            final String tag = trim(current, '"');

            //print("tag ($client): $tag");
            if (clientAliases.containsKey(tag)) {
                final alias = clientAliases[tag]!;
                splitTags[i] = (hasQuotes) ? "\"$alias\"" : alias;
            }
        }

        //okulog.d("After ($client): $splitTags");

        return splitTags.join(" ");
    }

    Future<void> cancelSearch() async {
        if (_completers.isEmpty) return;

        final lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }

    Future<Post?> getPost(int postID, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await _clients[client]?.getPost(postID);
        }

        for (final subfinder in _clients.values) {
            final post = await subfinder.getPost(postID);

            if (post != null) return post;
        }

        return null;
    }

    Future<List<Comment>> searchComments({String? client, int? postID, int limit = 100, int? page}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).searchComments(postID: postID, limit: limit, page: page);
        }

        final List<Comment> allComments = [];

        for (final subfinder in _clients.values) {
            final comments = await subfinder.searchComments(postID: postID, limit: limit, page: page);
            allComments.addAll(comments);
        }

        return allComments;
    }

    Future<Comment?> getComment(int commentID, {int? postID, String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await _clients[client]?.getComment(commentID, postID: postID);
        }

        for (final subfinder in _clients.values) {
            final comment = await subfinder.getComment(commentID, postID: postID);
            if (comment != null) return comment;
        }

        return null;
    }

    Future<List<Note>> getNotes(int postID, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).getNotes(postID);
        }

        final List<Note> allNotes = [];

        for (final subfinder in _clients.values) {
            final notes = await subfinder.getNotes(postID);

            allNotes.addAll(notes);
        }

        return allNotes;
    }

    Future<Description?> getDescription(int postID, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return await (_clients[client] as ISubfinder).getDescription(postID);
        }
        
        for (final subfinder in _clients.values) {
            final description = await subfinder.getDescription(postID);
            if (description != null) return description;
        }

        return null;
    }

    Future<Post?> postGetParent(Post post, {String? client}) async {
        if (client != null) {
            _checkSubfinderExists(client);
            return (_clients[client])?.postGetParent(post);
        }

        if (_clients.containsKey(post.source)) {
            return (_clients[post.source])?.postGetParent(post);
        }

        for (final subfinder in _clients.values) {
            final parentPost = await subfinder.postGetParent(post);
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

        for (final subfinder in _clients.values) {
            final childrenPosts = await subfinder.postGetChildren(post);
            if (childrenPosts.isNotEmpty) return childrenPosts;
        }

        return List<Post>.empty(growable: true);
    }

    Future<List<String?>> downloadFast(List<Post> posts, String path) async {
        final Executor executor = Executor(concurrency: 7);
        final List<String?> savePaths = [];

        final List<Post> randomizedPosts = List<Post>.from(posts);
        randomizedPosts.shuffle();

        for (final post in randomizedPosts) {
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
        
        final Executor executor = Executor(concurrency: 15);

        for (final post in posts) {
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
        final obj = DownloadStream(posts);

        if (onFetched != null) {
            obj.start(onFetched, onFinished: onFinished);
        }

        return obj;
    }

    static List<Post> filterByMD5(List<Post> posts, {bool generateMD5 = false}) {
        final List<String> md5Hashes = [];

        bool innerFilter(Post post) {
            if (post.md5.isEmpty && !generateMD5) return true;

            if (md5Hashes.contains(post.md5[0])) return false;

            md5Hashes.add(post.md5[0]);
            return true;
        }

        return posts.where((element) => innerFilter(element)).toList();
    }

    void _onConfigChange(String key, dynamic value, bool isCookie, bool isHeader) {
        for (final subfinder in _clients.values) {
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

