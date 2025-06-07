import "dart:collection";
import "dart:convert";
import "dart:math";
import "package:async/async.dart";
import "package:executor/executor.dart";
import "package:intl/intl.dart";
import "package:nokufind/src/description.dart";

import "subfinder.dart";
import "../API/pixiv_api.dart";
import "../Utils/utils.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";

class PixivFinder implements ISubfinder {
    static final Map<String, int> _artists = {};
    static final HashSet<int> _artistIDs = HashSet<int>();
    static final String formatString = "yyyy-MM-dd'T'HH:mm:ssZ";
    static final DateFormat formatter = DateFormat(formatString);

    static bool anyContains(List<Tag> list, String text) {
        for (final item in list) {
            if (item.original == text || item.translated == text) {
                return true;
            }
        }

        return false;
    }

    static Post toPost(Map<String, dynamic> postData) {
        final int pageCount = postData["page_count"] ?? 1;
        final List<String> urls = [];
        final List<String> altUrls = [];
        List<Tag> tags = [];
        final List originalTags = List<dynamic>.from(postData["tags"]!);

        try {
            tags = originalTags.map<Tag>((element) => Tag(element["name"], translated: element["translated_name"] ?? "")).toList();
        } catch (e, stackTrace) {
            Nokulog.e(jsonEncode(postData), error: e, stackTrace: stackTrace);
        }

        final String artistName = postData["user"]["name"].toString();
        final int artistID = postData["user"]["id"];

        if (!originalTags.contains(artistName)) {
            tags.add(Tag(artistName));
        }

        if (postData["illust_ai_type"] == 2) {
            tags.add(Tag("AI-generated"));
        }

        tags.add(Tag("artist:$artistID"));

        _artists[artistName] = artistID;

        if (pageCount > 1) {
            for (final page in postData["meta_pages"]) {
                urls.add(page["image_urls"]["original"]);
                altUrls.add(page["image_urls"]["large"]);
            }
        } else {
            urls.add(postData["meta_single_page"]["original_image_url"]);
            altUrls.add(postData["image_urls"]["large"]);
        }
    

        // List<int>.from([postData["width"], postData["height"]])
        return Post(
            postID: postData["id"], 
            tags: tags, 
            sources: [],
            images: urls, 
            authors: [postData["user"]["name"].toString()], 
            source: "pixiv",
            preview: postData["image_urls"]["medium"], 
            md5: null, 
            rating: (anyContains(tags, "R-18") || anyContains(tags, "R-18G")) ? Rating.explicit : Rating.unknown, 
            parentID: null, 
            dimensions: List<Dimensions>.filled(urls.length, Dimensions(postData["width"], postData["height"])), 
            poster: postData["user"]["name"],
            posterID: postData["user"]["id"], 
            title: postData["title"]
        )..setHeaders({"Referer": "https://pixiv.net"});
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        String stampURLData = "";

        if (commentData["stamp"] != null) {
            stampURLData = "<img src=\"${commentData["stamp"]["stamp_url"]}\">\n";
        }

        return Comment(
            commentID: commentData["id"], 
            postID: commentData["post_id"], 
            creatorID: commentData["user"]["id"],
            creator: commentData["user"]["name"] ?? "User ${commentData['user']['id']}", 
            creatorAvatar: commentData["user"]?["profile_image_urls"]?["medium"],
            body: "$stampURLData${commentData['comment']}", 
            source: "pixiv", 
            createdAt: formatter.parse(commentData["date"])
        );
    }

    static Note toNote(Map<String, dynamic> noteData) {
        throw Exception("Pixiv has no concept of notes. Do not use toNote.");
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        final int postID = descriptionData["id"];
        final String? originalDescription = descriptionData["caption"];

        if (originalDescription == null) {
            throw ArgumentError.notNull("caption");
        }

        return Description(
            postID: postID, 
            originalDescription: originalDescription, 
            source: "pixiv", 
            createdAt: formatter.parse(descriptionData["create_date"])
        );
    }

    final AppPixivAPI _client = AppPixivAPI();
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];
    final String refreshToken;

    bool _hasAuth = false;
    DateTime? _lastTime;

    PixivFinder(this.refreshToken, {String? acceptLanguage}) {
        _tryAuth();
        _config.setProperty("use_lower_quality", false);
        _config.setProperty("accept_language", "en-us");
        _config.lockProperties();

        _client.setAcceptLanguage(acceptLanguage ?? "en-us");
    }

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        if (!await _tryAuth()) return [];
        
        page = (page == null || page < 0) ? 1 : page + 1;

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final searchFuture = _getAllPosts(tags, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    @override
    Future<List<Post>> searchPostsAdvanced(String tags, {String optionalTags = "", String blacklist = "", int limit = 100, int? page}) {
        final List<String> splitTags = parseTagsWithQuotes(tags);
        final Iterable<String> splitBlacklist = parseTagsWithQuotes(tags).map((element) => "-$element");
        
        return searchPosts([...splitTags, ...splitBlacklist].join(" "));
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;
        if (!await _tryAuth()) return null;

        Map<String, dynamic>? rawPost; 

        try {
            rawPost = (await _client.illustDetail(postID))["illust"];

            if (_config.getConfig<bool>("use_lower_quality", defaultValue: false) == true) {
                rawPost?["use_lower_quality"] = true;
            }

        } catch(e, stackTrace) {
            Nokulog.e("Failed to fetch Pixiv post $postID.", error: e, stackTrace: stackTrace);
        }

        final result = (rawPost != null) ? toPost(rawPost) : null;
        return result;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;

        if (!await _tryAuth()) return [];

        List<Map<String, dynamic>> rawComments = [];

        try {
            if (postID == null) {
                rawComments = await _getCommentsFromRandomPosts(limit: limit, page: page);
            } else {
                final results = await _client.illustComments(postID);
                
                if (!results.containsKey("comments")) {
                    Nokulog.e("Map doesn't contain \"comments\" key.");
                    return [];
                }

                for (final result in (results["comments"] as List)) {
                    final currentComment = Map<String, dynamic>.from(result);
                    currentComment["post_id"] = postID;
                    rawComments.add(currentComment);
                }
            }

        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch Pixiv comments.", error: e, stackTrace: stackTrace);
        }

        return [for (final rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        if (!await _tryAuth()) return null;

        if (postID == null) return null;

        final results = await searchComments(postID: postID);
        
        try {
            return results.firstWhere((element) => element.commentID == commentID);
        } on StateError {
            Nokulog.w("No comment with ID $commentID exists for post $postID.");
        } catch(e, stackTrace) {
            Nokulog.e("Unexpected error occurred whilst fetching comment.", error: e, stackTrace: stackTrace);
        }

        return null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        return const [];
    }

    @override
    Future<Description?> getDescription(int postID) async {
        if (postID <= 0) return null;
        if (!await _tryAuth()) return null;

        try {
            final Map<String, dynamic> rawPost = (await _client.illustDetail(postID))["illust"];

            final String? caption = rawPost["caption"];

            if (caption == null || caption.isEmpty) {
                return null;
            }

            return toDescription(rawPost);
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch post description.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    @override
    Future<Post?> postGetParent(Post post) async {
        return null;
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        return const [];
    }

    @override
    Future<void> cancelLastSearch() async {
        if (_completers.isEmpty) return;

        final lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 30, int? page, bool canUseExecutor = false}) async {
        if (completer.isCanceled) return [];

        page = (page == null || page <= 0) ? 1 : page;

        if (tags.contains("artist:")) {
            return _getPostsWithArtist(tags, completer, limit: limit, page: page);
        }

        List<Post> currentPosts = [];
        final int defaultSize = 30;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        int? artistID = _artists[tags];
        bool shouldCheckForArtist = (artistID == null);
        final bool lowerQuality = _config.getConfig<bool>("use_lower_quality", defaultValue: false) == true;

        if (!shouldCheckForArtist) {
            Nokulog.i("Artist with name \"$tags\" ($artistID) is recorded in artist registry.");
        }

        final maxCount = (limit / defaultSize).ceil();

        if (canUseExecutor && maxCount > 10) {
            Nokulog.i("Max count: $maxCount");
            final Executor executor = Executor(concurrency: maxCount, rate: Rate.perSecond(10));

            for (var i = currentPage - 1; i < maxCount; ++i) {
                if (completer.isCanceled) return [];

                executor.scheduleTask(() async {
                    if (completer.isCanceled) {
                        await executor.close();
                        return;
                    }

                    final int currentOffset = (i * defaultSize);
                    Map<String, dynamic> results;
                    try {
                        results = (artistID == null) ? ((tags.isEmpty) ? await _client.illustRanking() : await _client.searchIllust(tags, offset: currentOffset)) 
                                : await _client.userIllusts(artistID, offset: currentOffset);
                    } catch (e, stackTrace) {
                        Nokulog.e("Failed to fetch Pixiv posts.", error: e, stackTrace: stackTrace);
                        return;
                    }

                    if (!results.containsKey("illusts")) {
                        return;
                    }

                    final rawPosts = List<Map<String, dynamic>>.from((results["illusts"] as List).map((element) => Map<String, dynamic>.from(element)));

                    if (rawPosts.isEmpty) return;

                    Nokulog.d("[nokufind.PixivFinder (Executor)]: Found ${rawPosts.length}.");

                    currentPosts.addAll(rawPosts.map((post) {
                        if (lowerQuality) {
                            post["use_lower_quality"] = true;
                        }
                        return toPost(post);
                    }));

                    Nokulog.d("[nokufind.PixivFinder (Executor)]: Currently at ${currentPosts.length} posts.");
                });
            }
            
            try {
                await executor.join(withWaiting: true);
                await executor.close();
            } catch (e, stackTrace) {
                Nokulog.e("In executor of Pixiv.", error: e, stackTrace: stackTrace);
            }

            currentPosts.sort((a, b) => a.postID.compareTo(b.postID));

            if (currentPosts.length > limit) {
                currentPosts = currentPosts.sublist(0, limit);
            }

            return currentPosts;
        }

        int tries = 0;
        final int maxTries = 5;

        while (currentSize == checkSize) {
            if (completer.isCanceled || tries >= maxTries) return [];
            final int currentOffset = ((currentPage - 1) * defaultSize);

            Map<String, dynamic> results;
            try {
                results = (artistID == null) ? ((tags.isEmpty) ? await _client.illustRanking() : await _client.searchIllust(tags, offset: currentOffset)) 
                        : await _client.userIllusts(artistID, offset: currentOffset);
            } catch (e, stackTrace) {
                Nokulog.e("Failed to fetch Pixiv posts.", error: e, stackTrace: stackTrace);
                tries++;
                continue;
            }
            if (completer.isCanceled) return [];

            if (!results.containsKey("illusts")) {
                break;
            }

            final rawPosts = List<Map<String, dynamic>>.from((results["illusts"] as List).map((element) => Map<String, dynamic>.from(element)));
            
            if (rawPosts.length < 5 && shouldCheckForArtist) {
                Nokulog.w("Search for \"$tags\" returned empty. Checking if artist.");
                final artistData = await _client.searchUser(tags);
                
                if ((artistData["user_previews"] as List).isEmpty) {
                    Nokulog.w("No artists or users with name \"$tags\" found. Breaking.");
                    break;
                }

                Nokulog.i("Found artist! Storing in record and starting anew.");
                
                for (final artist in (artistData["user_previews"] as List)) {
                    final int currentID = artist["user"]["id"];
                    final String currentName = artist["user"]["name"];

                    if (!_artists.containsKey(currentName)) {
                        Nokulog.i("Adding \"$currentName\" to artist registry.");
                        _artists[currentName] = currentID;
                    }

                    _artistIDs.add(currentID);

                    if (artistID != null) continue;

                    artistID = currentID;
                    shouldCheckForArtist = false;
                    Nokulog.i("artistID is now $artistID");
                }

                if (completer.isCanceled) return [];

                if (maxCount > 10) {
                    return _getAllPosts(tags, completer, limit: limit, canUseExecutor: true);
                }

                continue;
            }

            Nokulog.d("[nokufind.PixivFinder]: Found ${rawPosts.length}.");

            currentSize = rawPosts.length;
            currentPosts.addAll(rawPosts.map((post) {
                if (lowerQuality) {
                    post["use_lower_quality"] = true;
                }
                return toPost(post);
            }));

            Nokulog.d("[nokufind.PixivFinder]: Currently at ${currentPosts.length} posts.");

            if (currentPosts.length >= limit) {
                break;
            }

            if (maxCount > 10) {
                currentPosts += await _getAllPosts(tags, completer, limit: limit, canUseExecutor: true);
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

    Future<List<Post>> _getPostsWithArtist(String tags, CancelableCompleter completer, {int limit = 30, int page = 1}) async {
        if (completer.isCanceled) return [];

        final List<String> tagList = parseTagsWithQuotes(tags);
        final Executor executor = Executor(concurrency: tagList.length);

        List<Post> currentPosts = [];
        final int defaultSize = 30;
        final int checkSize = min(defaultSize, limit);
        final bool lowerQuality = _config.getConfig<bool>("use_lower_quality", defaultValue: false) == true;

        final HashSet<String> artistTags = HashSet.from(tagList.where((item) => item.startsWith("artist:") || _artists.containsKey(item)));

        final List<Map<String, dynamic>> totalRawPosts = [];

        for (final String tag in artistTags) {
            int? artistID;

            if (tag.startsWith("artist:")) {
                final String lastPart = tag.replaceAll("artist:", "");
                final int? possibleID = int.tryParse(lastPart);

                if (possibleID != null && !_artistIDs.contains(possibleID)) {
                    // In the case that the ID is an actual valid user ID, we should fetch the name to store it internally.
                    executor.scheduleTask(() async {
                        try {
                            final artist = await _client.userDetail(possibleID);

                            final String name = artist["user"]["name"];

                            if (!_artists.containsKey(name)) _artists[name] = possibleID;
                        
                            _artistIDs.add(possibleID);
                        } catch (e, stackTrace) {
                            Nokulog.e("No artist with given ID $possibleID found.", error: e, stackTrace: stackTrace);
                        }
                    });
                }

                artistID = possibleID ?? await _getArtistID(lastPart);

                if (artistID == null) {
                    Nokulog.w("Artist ID is null.");
                    await executor.close();
                    return [];
                }
            }

            artistID ??= _artists[tag]!;

            executor.scheduleTask(() async {
                if (completer.isCanceled) return;

                Nokulog.d("Inside task.");
                int currentSize = checkSize;
                int currentPage = page;

                while (currentSize == checkSize) {
                    try {
                        Nokulog.d("currentPage: $currentPage");
                        final int currentOffset = (currentPage - 1) * defaultSize;
                        final results = await _client.userIllusts(artistID, offset: currentOffset);

                        if (completer.isCanceled) return;

                        final rawPosts = List<Map<String, dynamic>>.from((results["illusts"] as List).map((element) => Map<String, dynamic>.from(element)));    
                        currentSize = rawPosts.length;

                        totalRawPosts.addAll(rawPosts);

                        currentPage++;
                    } catch (e, stackTrace) {
                        Nokulog.e("Error occured while fetching posts from user \"$tag\" ($artistID).", error: e, stackTrace: stackTrace);
                    }
                }
            });
        }

        await executor.join(withWaiting: true);

        if (completer.isCanceled) return [];

        currentPosts.addAll(totalRawPosts.map((post) {
            if (lowerQuality) {
                post["use_lower_quality"] = true;
            }
            return toPost(post);
        }));

        if (tagList.length != artistTags.length) {
            currentPosts.removeWhere((item) {
                for (final tag in tagList) {
                    if (artistTags.contains(tag)) return false;
                    
                    bool shouldRemove = true;
                    for (final innerTag in item.tags) {
                        if (innerTag.contains(tag)) {
                            shouldRemove = false;
                            break;
                        }
                    }

                    if (shouldRemove) {
                        return true;
                    }
                }

                return false;
            });
        }

        if (currentPosts.length > limit) {
            currentPosts = currentPosts.sublist(0, limit);
        }

        return currentPosts;
    }

    Future<int?> _getArtistID(String artistName) async {
        int? artistID;
        final artistData = await _client.searchUser(artistName);
                
        if ((artistData["user_previews"] as List).isEmpty) {
            Nokulog.w("No artists or users with name \"$artistName\" found. Returning.");
            return null;
        }

        Nokulog.i("Found artist! Storing in record and starting anew.");
        
        for (final artist in (artistData["user_previews"] as List)) {
            final int currentID = artist["user"]["id"];
            final String currentName = artist["user"]["name"];

            if (!_artists.containsKey(currentName)) _artists[currentName] = currentID;

            _artistIDs.add(currentID);
            
            if (artistID != null) continue;

            artistID = currentID;
        }

        return artistID;
    }
    
    Future<List<Map<String, dynamic>>> _getCommentsFromRandomPosts({int limit = 30, int? page}) async {
        page = (page == null) ? 1 : page;
        
        List<Map<String, dynamic>> comments = [];

        final int defaultSize = 30;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            final int currentOffset = (currentPage - 1) * 30;

            final response = await _client.illustRanking(offset: currentOffset);
            final List currentPosts = response["illusts"];

            currentSize = currentPosts.length;

            for (final post in currentPosts) {
                final int postID = post["id"];

                final commentResponse = await _client.illustComments(postID, includeTotalComments: true);

                if (!commentResponse.containsKey("comments")) continue;

                final List currentComments = commentResponse["comments"];

                for (final commentData in currentComments) {
                    final comment = Map<String, dynamic>.from(commentData);
                    comment["post_id"] = postID;
                    comments.add(comment);
                }

                if (comments.length >= limit) {
                    break;
                }
            }

            if (comments.length >= limit) {
                break;
            }

            currentPage++;
        }

        if (comments.length > limit) {
            comments = comments.sublist(0, limit);
        }

        return comments;
    }

    Future<bool> _tryAuth() async {
        final DateTime currentTime = DateTime.now();
        _lastTime = _lastTime ?? DateTime.now();

        final Duration timeDifference = currentTime.difference(_lastTime!);

        if (_hasAuth && timeDifference.inSeconds < 3600) return true;

        try {
            await _client.auth(refreshToken: refreshToken);
            _hasAuth = true;
            _lastTime = DateTime.now();
            return true;
        } catch(e, stackTrace) {
            _hasAuth = false;
            Nokulog.e("Failed to authenticate user.", error: e, stackTrace: stackTrace);
            return false;
        }
    }

    @override
    SubfinderConfiguration get configuration => _config;
}