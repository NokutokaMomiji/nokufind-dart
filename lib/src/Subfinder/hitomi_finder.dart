

import "dart:math";

import "package:async/async.dart";
import "package:nokufind/src/Utils/utils.dart";
import "package:nokufind/src/description.dart";

import "subfinder.dart";
import "../API/hitomi_api.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";

class HitomiFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        final List<Tag> tags = (postData["tags"] as List<String>).map((element) => Tag(element, type: TagType.general)).toList();
        tags.addAll((postData["artists"] as List<String>).map((element) => Tag(element, type: TagType.artist)));
        tags.addAll((postData["characters"] as List<String>).map((element) => Tag(element, type: TagType.character)));
        tags.addAll((postData["parodies"] as List<String>).map((element) => Tag(element, type: TagType.series)));

        return Post(
            postID: postData["postID"], 
            tags: tags, 
            sources: [], 
            images: postData["images"], 
            authors: postData["authors"],
            source: "hitomi", 
            preview: postData["preview"], 
            md5: postData["hashes"],
            rating: "e", 
            parentID: null, 
            dimensions: postData["dimensions"], 
            poster: "Unknown",
            posterID: null, 
            title: postData["title"]
        )..setHeaders({"Referer": "https://hitomi.la", "User-Agent": userAgent});
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        throw Exception("Hitomi has no concept of comments. Do not use \"toComment\".");
    }

    static Note toNote(Map<String, dynamic> noteData) {
        throw Exception("Hitomi has no concept of notes. Do not use \"toNote\".");
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        throw UnimplementedError("Hitomi has no descriptions. Do not use \"toDescription\".");
    }

    final HitomiAPI _client;
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    HitomiFinder({bool preferWebp = true}) : _client = HitomiAPI(preferWebp: preferWebp);

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page + 1;
        
        await _client.configureCommon();

        final rawPosts = await _client.searchPosts(tags, limit: limit, page: page);

        return rawPosts.map(toPost).toList();
    }

    @override
    Future<List<Post>> searchPostsAdvanced(String tags, {String optionalTags = "", String blacklist = "", int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page + 1;

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final List<String> baseTags = tags.trim().split(" ");
        final List<String> splitOptionalTags = optionalTags.trim().split(" ")..removeWhere((element) => baseTags.contains(element) || element.isEmpty);
        final Iterable<String> blacklistTags = (blacklist.isNotEmpty) ? blacklist.trim().split(" ").map((element) => "-$element") : [];

        final List<String> queries;
        if (splitOptionalTags.isEmpty) {
            // Only base tags + blacklist
            queries = [[
                    ...baseTags,
                    ...blacklistTags,
                ].where(
                    (element) => element.isNotEmpty
                ).join(" "),
            ];
        } else {
            // One query for each optional tag
            queries = splitOptionalTags.map((optTag) {
                return [
                    ...baseTags,
                    optTag,
                    ...blacklistTags,
                ].where(
                    (element) => element.isNotEmpty
                ).join(" ");
            }).toList();
        }

        final int postsPerQuery = (limit / queries.length).ceil();

        final futures = queries.map(
            (query) => () async {
                if (completer.isCanceled) return <Map<String, dynamic>>[];

                Nokulog.i("query: $query");
                return await _client.searchPosts(
                    query,
                    limit: postsPerQuery,
                    page: page ?? 1,
                );
            }(),
        ).toList();

        _completers.add(completer);

        final rawPosts = () async {
            final results = (await Future.wait(futures));
            final result = (results.isNotEmpty) ? results.reduce((value, element) => value + element) : <Map<String, dynamic>>[];
            return result.map(toPost).toList();
        }();

        completer.complete(rawPosts);

        return (await completer.operation.valueOrCancellation()) ?? <Post>[];
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        await _client.configureCommon();

        final rawPost = await _client.getPost(postID);

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
       return [];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        return null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        return [];
    }

    @override
    Future<Description?> getDescription(int postID) async {
        return null;
    }

    @override
    Future<Post?> postGetParent(Post post) async {
        return null;
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        return [];
    }

    @override
    Future<void> cancelLastSearch() async {
        if (_completers.isEmpty) return;

        final lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }
    
    bool get preferWebp => _client.preferWebp;
    set preferWebp(bool value) {
        _client.preferWebp = value;
    }

    @override
    SubfinderConfiguration get configuration => _config;
}