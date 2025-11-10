

import "dart:math";

import "package:async/async.dart";
import "package:nokufind/src/description.dart";

import "subfinder.dart";
import "../API/nhentai_api.dart";
import "../Utils/utils.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";


/*List<Map<String, dynamic>> _filterInvalidPosts(List<Map<String, dynamic>> posts) {
    return posts.where((element) => element.containsKey("md5") && element.containsKey("file_url")).toList();
}

List<Map<String, dynamic>> _filterInvalidComments(List<Map<String, dynamic>> comments) {
    return comments.where((element) => element.containsKey("body") && !element["is_deleted"]).toList();
}*/

class NHentaiFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        if (postData["id"] is String) {
            postData["id"] = int.parse(postData["id"]);
        }

        final artists = List<String>.from(postData["authors"]);
        final tags = List<String>.from(postData["tags"]).map((element) => Tag(element)).toList();

        tags.addAll(List<String>.from(postData["characters"]).map((element) => Tag(element, type: TagType.character)));
        tags.addAll(List<String>.from(postData["sources"]).map((element) => Tag(element, type: TagType.series)));
        tags.addAll(artists.map((element) => Tag(element, type: TagType.artist)));

        return Post(
            postID: postData["id"], 
            tags: tags, 
            sources: ["https://nhentai.net/g/${postData['id']}"], 
            images: List<String>.from(postData["images"]), 
            authors: artists, //(postData["tag_string_artist"] as String).split(" "), 
            source: "nhentai", 
            preview: postData["preview_url"], 
            md5: [], 
            rating: Rating.explicit, 
            parentID: null,
            dimensions: postData["dimensions"], 
            poster: postData["poster"] ?? "Unknown",
            posterID: null, 
            title: postData["title"]
        );
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        return Comment(
            commentID: commentData["id"], 
            postID: commentData["post_id"], 
            creatorID: commentData["creator_id"],
            creator: commentData["creator"] ?? "User ${commentData['creator_id']}",
            body: commentData["body"], 
            creatorAvatar: commentData["creator_avatar"],
            source: "nhentai",
            createdAt: commentData["created_at"] as DateTime
        );
    }

    static Note toNote(Map<String, dynamic> noteData) {
        throw Exception("NHentai has no notes.");
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        throw UnimplementedError("NHentai has no descriptions. Do not use toDescription.");
    }

    late NHentaiAPI _client;

    NHentaiFinder(String cfClearance, String csrfToken, String sessionAffinity) {
        _client = NHentaiAPI(cfClearance, csrfToken, sessionAffinity);

        _config.setProperty("cfClearance", cfClearance);
        _config.setProperty("csrfToken", csrfToken);
        _config.setProperty("sessionAffinity", sessionAffinity);
        _config.lockProperties();
        
        _config.setCallback(
            (key, value, isCookie, isHeader) {
                switch (key) {
                    case "cfClearance":
                        final newValue = value.toString();
                        final csrfTokenA = _config.getConfig<String>("csrfToken", defaultValue: csrfToken);
                        final sessionAffinityA = _config.getConfig<String>("sessionAffinity", defaultValue: sessionAffinity);
                        _client = NHentaiAPI(newValue, csrfTokenA, sessionAffinityA);

                    default:
                        return;
                }
            },
        );
    }

    final _config = SubfinderConfiguration();

    final List<CancelableCompleter> _completers = [];

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 25, int? page}) async {
        page = (page == null) ? 1 : page;
        page = (page <= 0) ? 1 : page;

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final searchFuture = _getAllPosts(tags, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return (await completer.operation.valueOrCancellation()) ?? <Post>[];
    }

    @override
    Future<List<Post>> searchPostsAdvanced(String tags, {String optionalTags = "", String blacklist = "", int limit = 100, int? page}) async {
        if (optionalTags.isEmpty && blacklist.isEmpty) {
            return searchPosts(tags, limit: limit, page: page);
        }

        page = (page == null) ? 0 : page - 1;
        page = (page < 0) ? 0 : page;

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final searchFuture = _getAdvancedPosts(tags, optionalTags, blacklist, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return (await completer.operation.valueOrCancellation()) ?? <Post>[];
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        final rawPost = await _client.getPost(postID);

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 0 : page;

        final rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        //rawComments = _filterInvalidComments(rawComments);

        return [for (final rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        if (postID == null) return null;

        final rawComment = await _client.getComment(commentID, postID);

        return (rawComment != null) ? toComment(rawComment) : null;
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

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 25, int? page}) async {
        if (completer.isCanceled) return [];

        page = (page == null) ? 0 : page;

        List<Post> currentPosts = [];
        final int defaultSize = 25;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            if (completer.isCanceled) return [];

            final rawPosts = await _client.searchPosts(tags, limit: limit, page: currentPage);

            if (completer.isCanceled) return [];

            currentSize = rawPosts.length;

            //rawPosts = _filterInvalidPosts(rawPosts);
            currentPosts.addAll(rawPosts.map(toPost));

            if (currentPosts.length >= limit) {
                break;
            }

            currentPage += 1;
        }

        currentPosts.sort((a, b) => a.postID.compareTo(b.postID));

        if (currentPosts.length > limit) {
            currentPosts = currentPosts.sublist(0, limit);
        }

        return currentPosts;
    }

    Future<List<Post>> _getAdvancedPosts(String tags, String optionalTags, String blacklist, CancelableCompleter completer, {int limit = 100, int? page}) async {
        if (completer.isCanceled) return [];

        // If the page index is null, we begin by 0.
        page = (page == null) ? 0 : page;

        blacklist = blacklist.trim();
        optionalTags = optionalTags.trim();

        // We split the tags and the optional tags by spaces since the client doesn't use quotes.
        final List<String> splitTags = parseTagsWithQuotes(tags.trim(), includeQuotes: true);
        final List<String> splitOptionalTags = (optionalTags.isNotEmpty) ? parseTagsWithQuotes(optionalTags, includeQuotes: true) : [];
        final Iterable<String> splitBlacklist = (blacklist.isNotEmpty) ? parseTagsWithQuotes(blacklist, includeQuotes: true).map((element) => "-$element") : [];
        final List<String> queries = [];

        if (splitOptionalTags.isEmpty) {
            return _getAllPosts([...splitTags, ...splitBlacklist].join(" "), completer, limit: limit, page: page);
        } else {
            for (final optionalTag in splitOptionalTags) {
                queries.add(
                    [...splitTags, optionalTag, ...splitBlacklist]  // We merge the tags, one optional tag, and the blacklisted tags.
                    .where((element) => element.isNotEmpty)         // We remove any empty strings.
                    .join(" ").trim()                               // We join them into a singular empty string.
                );
            }
        }

        final int postsPerQuery = (limit / queries.length).ceil();

        List<Post> currentPosts = [];
        final int defaultSize = 25;
        final int checkSize = min(min(defaultSize, limit), postsPerQuery);
        int currentSize = checkSize;
        int currentPage = (limit > checkSize) ? (page * (limit / checkSize)).floor() : page;

        final Map<String, bool> queryIsExhausted = {for (final query in queries) query: false};

        while (currentSize == checkSize) {
            if (completer.isCanceled) return [];

            if (queryIsExhausted.values.every((value) => value)) {
                break;
            }

            final futures = queries.where((element) => !(queryIsExhausted[element]!)).map((query) {
                return () async {
                    if (completer.isCanceled) return <Map<String, dynamic>>[];

                    final results = await _client.searchPosts(query, limit: checkSize, page: currentPage);

                    if (results.length < checkSize) {
                        queryIsExhausted[query] = true;
                    }

                    return results;
                }();
            });

            if (completer.isCanceled) return [];

            final results = await Future.wait(futures);

            if (results.isEmpty) {
                break;
            }
            
            for (final result in results) {
                currentPosts.addAll(result.map(toPost));
                currentSize = max(currentSize, result.length);
            }

            if (currentPosts.length >= limit) {
                break;
            }

            currentPage += 1;
        }

        currentPosts.sort((a, b) => a.postID.compareTo(b.postID));

        if (currentPosts.length > limit) {
            currentPosts = currentPosts.sublist(0, limit);
        }

        return currentPosts;
    }
    
    @override
    SubfinderConfiguration get configuration => _config;
}