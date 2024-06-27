import "dart:convert";
import "dart:math";
import "package:intl/intl.dart";

import "subfinder.dart";
import "../Utils/pixiv_api.dart";
import "../Utils/utils.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";

class PixivFinder implements ISubfinder {
    static final Map<String, int> _artists = {};
    static final String formatString = "yyyy-MM-dd'T'HH:mm:ssZ";
    static final DateFormat formatter = DateFormat(formatString);

    static bool anyContains(List<Tag> list, String text) {
        for (var item in list) {
            if (item.original == text || item.translated == text) {
                return true;
            }
        }

        return false;
    }

    static Post toPost(Map<String, dynamic> postData) {
        int pageCount = postData["page_count"] ?? 1;
        List<String> urls = [];
        List<Tag> tags = [];
        List originalTags = List<dynamic>.from(postData["tags"]!);

        try {
            tags = originalTags.map<Tag>((element) => Tag(element["name"], translated: element["translated_name"] ?? "")).toList();
        } catch (e, stackTrace) {
            Nokulog.logger.e(jsonEncode(postData), error: e, stackTrace: stackTrace);
        }

        String artistName = postData["user"]["name"].toString();
        int artistID = postData["user"]["id"];

        if (!originalTags.contains(artistName)) {
            tags.add(Tag(artistName));
        }

        _artists[artistName] = artistID;

        bool useLowerVersion = postData.containsKey("use_lower_quality");

        if (pageCount > 1) {
            for (var page in postData["meta_pages"]) {
                urls.add(page["image_urls"][(useLowerVersion) ? "large" : "original"]);
            }
        } else {
            urls.add((useLowerVersion) ? postData["image_urls"]["large"] : postData["meta_single_page"]["original_image_url"]);
        }
    
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
            dimensions: List<List<int>>.filled(urls.length, List<int>.from([postData["width"], postData["height"]])), 
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

    final AppPixivAPI _client = AppPixivAPI();
    final _config = SubfinderConfiguration();
    final String refreshToken;

    bool _hasAuth = false;
    DateTime? _lastTime;

    PixivFinder(this.refreshToken, {String? acceptLanguage}) {
        _tryAuth();
        _config.setProperty("use_lower_quality", false);
        _config.lockProperties();

        _client.setAcceptLanguage(acceptLanguage ?? "en-us");
    }

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        if (!await _tryAuth()) return [];
        
        page = (page == null || page <= 0) ? 1 : page;

        return await _getAllPosts(tags, limit: limit, page: page);
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
            Nokulog.logger.e("Failed to fetch Pixiv post $postID.", error: e, stackTrace: stackTrace);
        }

        return (rawPost != null) ? toPost(rawPost) : null;
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
                var results = await _client.illustComments(postID);
                
                if (!results.containsKey("comments")) {
                    Nokulog.logger.e("Map doesn't contain \"comments\" key.");
                    return [];
                }

                for (var result in (results["comments"] as List)) {
                    var currentComment = Map<String, dynamic>.from(result);
                    currentComment["post_id"] = postID;
                    rawComments.add(currentComment);
                }
            }

        } catch (e, stackTrace) {
            Nokulog.logger.e("Failed to fetch Pixiv comments.", error: e, stackTrace: stackTrace);
        }

        return [for (var rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        if (!await _tryAuth()) return null;

        if (postID == null) return null;

        var results = await searchComments(postID: postID);
        
        try {
            return results.firstWhere((element) => element.commentID == commentID);
        } on StateError {
            Nokulog.logger.w("No comment with ID $commentID exists for post $postID.");
        } catch(e, stackTrace) {
            Nokulog.logger.e("Unexpected error occurred whilst fetching comment.", error: e, stackTrace: stackTrace);
        }

        return null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        return const [];
    }

    @override
    Future<Post?> postGetParent(Post post) async {
        return null;
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        return const [];
    }

    Future<List<Post>> _getAllPosts(String tags, {int limit = 30, int? page}) async {
        page = (page == null || page <= 0) ? 1 : page;

        List<Post> currentPosts = [];
        int defaultSize = 30;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        int? artistID = _artists[tags];
        bool shouldCheckForArtist = (artistID == null);
        bool lowerQuality = _config.getConfig<bool>("use_lower_quality", defaultValue: false) == true;

        if (!shouldCheckForArtist) {
            Nokulog.logger.i("Artist with name \"$tags\" ($artistID) is recorded in artist registry.");
        }

        while (currentSize == checkSize) {
            int currentOffset = ((currentPage - 1) * defaultSize);

            var results = (artistID == null) ? ((tags.isEmpty) ? await _client.illustRanking() : await _client.searchIllust(tags, offset: currentOffset)) 
                            : await _client.userIllusts(artistID, offset: currentOffset);

            var rawPosts = List<Map<String, dynamic>>.from((results["illusts"] as List).map((element) => Map<String, dynamic>.from(element)));
            
            if (rawPosts.length < 5 && shouldCheckForArtist) {
                Nokulog.logger.w("Search for \"$tags\" returned empty. Checking if artist.");
                var artistData = await _client.searchUser(tags);
                
                if ((artistData["user_previews"] as List).isEmpty) {
                    Nokulog.logger.w("No artists or users with name \"$tags\" found. Breaking.");
                    break;
                }

                Nokulog.logger.i("Found artist! Storing in record and starting anew.");
                
                for (var artist in (artistData["user_previews"] as List)) {
                    int currentID = artist["user"]["id"];
                    String currentName = artist["user"]["name"];

                    _artists[currentName] = currentID;

                    if (artistID != null) continue;

                    artistID = currentID;
                }

                continue;
            }

            Nokulog.logger.d("[nokufind.PixivFinder]: Found ${rawPosts.length}.");

            currentSize = rawPosts.length;
            currentPosts.addAll(rawPosts.map((post) {
                if (lowerQuality) {
                    post["use_lower_quality"] = true;
                }
                return toPost(post);
            }));

            Nokulog.logger.d("[nokufind.PixivFinder]: Currently at ${currentPosts.length} posts.");

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
    
    Future<List<Map<String, dynamic>>> _getCommentsFromRandomPosts({int limit = 30, int? page}) async {
        page = (page == null) ? 1 : page;
        
        List<Map<String, dynamic>> comments = [];

        int defaultSize = 30;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            int currentOffset = (currentPage - 1) * 30;

            var response = await _client.illustRanking(offset: currentOffset);
            List currentPosts = response["illusts"];

            currentSize = currentPosts.length;

            for (var post in currentPosts) {
                int postID = post["id"];

                var commentResponse = await _client.illustComments(postID, includeTotalComments: true);

                if (!commentResponse.containsKey("comments")) continue;

                List currentComments = commentResponse["comments"];

                for (var commentData in currentComments) {
                    var comment = Map<String, dynamic>.from(commentData);
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
        DateTime currentTime = DateTime.now();
        _lastTime = _lastTime ?? DateTime.now();

        Duration timeDifference = currentTime.difference(_lastTime!);

        if (_hasAuth && timeDifference.inSeconds < 3600) return true;

        try {
            await _client.auth(refreshToken: refreshToken);
            _hasAuth = true;
            _lastTime = DateTime.now();
            return true;
        } catch(e, stackTrace) {
            _hasAuth = false;
            Nokulog.logger.e("Failed to authenticate user.", error: e, stackTrace: stackTrace);
            return false;
        }
    }

    @override
    SubfinderConfiguration get configuration => _config;
}