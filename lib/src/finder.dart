import 'dart:async';
import 'dart:core';

import 'package:executor/executor.dart';
import 'package:nokufind/src/Utils/download_stream.dart';

import 'Subfinder/subfinder.dart';
import 'Subfinder/danbooru_finder.dart';
import 'Subfinder/rule34_finder.dart';
import 'Subfinder/konachan_finder.dart';
import 'Subfinder/yandere_finder.dart';
import 'Subfinder/gelbooru_finder.dart';

import 'post.dart';
import 'comment.dart';
import 'note.dart';
import 'Utils/utils.dart';

class NoSuchSubfinderException implements Exception {
    String cause;
    NoSuchSubfinderException(this.cause);

    @override
    String toString() => cause;
}

class DisabledSubfinderException implements Exception {
    String cause;
    DisabledSubfinderException(this.cause);

    @override
    String toString() => cause;
}

class Finder {
    final Map<String, ISubfinder> _clients = {};
    late final SubfinderConfiguration _config;
    Executor? _executor;
    
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

        Nokulog.logger.d(aliases[client].remove(tag));
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

        var aliases = configuration.getConfig("aliases") as Map;

        if (client != null) {
            _checkSubfinderExists(client);

            final bool isEnabled = _config.getConfig<Map>("enabled")![client]!;

            if (!isEnabled) {
                throw DisabledSubfinderException("Subfinder \"$client\" was selected but is disabled.");
            }

            var clientAliases = Map<String, String>.from(aliases[client]);
            String resultTags = tags;

            clientAliases.forEach((key, value) {
                resultTags = resultTags.replaceAll(key, value);
            });

            var posts = await (_clients[client] as ISubfinder).searchPosts(resultTags, limit: limit, page: page);
            
            if (posts.isEmpty) {
                Nokulog.logger.d("[nokufind.Finder]: $client returned no posts.");
            }
            
            return posts;
        }

        _executor = _executor ?? Executor(concurrency: 15, rate: Rate.perSecond(10));
        List<Post> allPosts = [];

        for (var client in _clients.entries) {
            try {
                final bool isEnabled = _config.getConfig<Map>("enabled")![client.key]!;

                if (!isEnabled) {
                    Nokulog.logger.d("Subfinder \"${client.key}\" is disabled. Skipping.");
                    continue;
                }
                
                _executor!.scheduleTask(() async {
                    var clientName = client.key;
                    var clientSubfinder = client.value;
                    var clientAliases = aliases[clientName] as Map;

                    var resultTags = tags;

                    clientAliases.forEach((key, value) {
                        resultTags = resultTags.replaceAll(key, value);
                    });

                    try {
                        var posts = await clientSubfinder.searchPosts(resultTags, limit: limit, page: page);
                        
                        if (posts.isEmpty) {
                            Nokulog.logger.w("[nokufind.Finder] $clientName returned no posts.");
                        }
                        
                        allPosts.addAll(posts);
                        return;
                    } on Exception catch (e, stackTrace) {
                        Nokulog.logger.e("[nokufind.Finder]: ($clientName) $e", error: e, stackTrace: stackTrace);
                        return;
                    }
                });
            } catch (e, stackTrace) {
                Nokulog.logger.e("[nokufind.Finder]: An error occurred when attempting to schedule a task.", error: e, stackTrace: stackTrace);
            }
        }

        await _executor!.join(withWaiting: true);

        return allPosts;
    }

    Future<void> cancelSearch() async {
        if (_executor == null) return;

        await _executor!.close();
        _executor = null;
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
        Executor executor = Executor(concurrency: 10);
        List<String?> savePaths = [];

        final List<Post> randomizedPosts = List<Post>.from(posts);
        randomizedPosts.shuffle();

        for (var post in randomizedPosts) {
            executor.scheduleTask(() async {
                try {
                    savePaths.addAll(await post.downloadAll(path));
                } catch (e) {
                    Nokulog.logger.d(e);
                }
            });
	    }

        await executor.join(withWaiting: true);
        await executor.close();

        return savePaths;
    }

    Future<void> fetchData(List<Post> posts, {bool onlyMainImage = false, bool shouldWait = true}) async {
        if (posts.isEmpty) {
            Nokulog.logger.d("> [nokufind.Finder]: Post list was empty. Exiting.");
            return;   
        }
        
        Executor executor = Executor(concurrency: 15);

        for (var post in posts) {
            executor.scheduleTask(() async {
                try {
                    
                    Nokulog.logger.d("Fetching ${post.identifier}...");
                    await post.fetchData(onlyMainImage: onlyMainImage, shouldWait: shouldWait);
                } catch (e) {
                    Nokulog.logger.d("[nokufind.Finder]: (${post.identifier}) $e");
                    return List<Post>.empty();
                }
            });
        }

        if (shouldWait) {
            await executor.join(withWaiting: true);
            await executor.close();
        }
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
            throw NoSuchSubfinderException(name);
        }
    }

    SubfinderConfiguration get configuration => _config;
    List<String> get clientNames => _clients.keys.toList();
    List<String> get enabledClients => _clients.keys.where((client) => subfinderIsEnabled(client)).toList();
}

