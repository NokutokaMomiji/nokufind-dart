

import "dart:math";

import "package:async/async.dart";
import "package:nokufind/src/description.dart";

import "subfinder.dart";
import "../API/yandere_api.dart";
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

class YandereFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        final int width = postData["width"];
        final int height = postData["height"];
        final String imageURL = postData["file_url"];

        final int jpegWidth = postData["jpeg_width"];
        final int jpegHeight = postData["jpeg_height"];
        final String jpegImageURL = postData["jpeg_url"];

        return Post(
            postID: postData["id"], 
            tags: (postData["tags"] as String).split(" "), 
            sources: (postData["source"] as String).split(" "), 
            images: [imageURL], 
            altImages: [jpegImageURL],
            authors: [], //(postData["tag_string_artist"] as String).split(" "), 
            source: "yande.re", 
            preview: postData["preview_url"],
            sample: postData["sample_url"],
            md5: [postData["md5"]], 
            rating: postData["rating"], 
            parentID: postData["parent_id"], 
            dimensions: [Dimensions(width, height, alt: Dimensions(jpegWidth, jpegHeight))], 
            poster: postData["author"] ?? "User ${postData['creator_id']}",
            posterID: postData["creator_id"], 
            title: null
        );
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        return Comment(
            commentID: commentData["id"], 
            postID: commentData["post_id"], 
            creatorID: commentData["creator_id"],
            creator: commentData["creator"] ?? "User ${commentData['creator_id']}",
            creatorAvatar: commentData["creator_avatar"],
            body: commentData["body"], 
            source: "yande.re",
            createdAt: commentData["created_at"] as DateTime
        );
    }

    static Note toNote(Map<String, dynamic> noteData) {
        return Note(
            noteID: noteData["id"], 
            createdAt: DateTime.parse(noteData["created_at"]), 
            x: noteData["x"], 
            y: noteData["y"], 
            width: noteData["width"], 
            height: noteData["height"], 
            body: noteData["body"], 
            source: "yande.re", 
            postID: noteData["post_id"]
        );
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        throw UnimplementedError("Yande.re has no descriptions. Do not use toDescription.");
    }

    final YandereAPI _client = YandereAPI();
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    YandereFinder() {
        _config.setProperty("use_lower_quality", false);
    }

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page + 1;

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
    Future<List<Post>> searchPostsAdvanced(String tags, {String optionalTags = "", String blacklist = "", int limit = 100, int? page}) {
        final baseTags = tags.trim().split(" ");
        final optionalTagList = (optionalTags.isNotEmpty) ? optionalTags.trim().split(" ").map((element) => "~$element") : <String>[];
        final blacklistTags = (blacklist.isNotEmpty) ? blacklist.trim().split(" ").map((element) => "-$element") : <String>[];

        final optionalTagString = (optionalTags.isNotEmpty) ? " ${optionalTagList.join(" ")}" : "";
        final blacklistString = (blacklist.isNotEmpty) ? " ${blacklistTags.join(" ")}" : "";

        return searchPosts(
            "${baseTags.join(" ")}$optionalTagString$blacklistString", 
            limit: limit, 
            page: page
        );
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        final rawPost = await _client.getPost(postID);

        if (_config.getConfig<bool>("use_lower_quality", defaultValue: false) == true) {
            rawPost?["use_lower_quality"] = true;
        }

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page + 1;

        final rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        //rawComments = _filterInvalidComments(rawComments);

        return [for (final rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        final rawComment = await _client.getComment(commentID);

        return (rawComment != null) ? toComment(rawComment) : null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        final rawNotes = await _client.getNotes(postID);

        if (rawNotes == null) {
            return List<Note>.empty(growable: true);
        }

        return [for (final rawNote in rawNotes) toNote(rawNote)];
    }

    @override
    Future<Description?> getDescription(int postID) async {
        return null;
    }

    @override
    Future<Post?> postGetParent(Post post) async {
        if (post.parentID == null) {
            return null;
        }

        return post.setParent(await getPost(post.parentID as int));
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        return post.setChildren((await searchPosts("parent:${post.postID}")).where((element) => element.postID != post.postID).toList());
    }

    @override
    Future<void> cancelLastSearch() async {
        if (_completers.isEmpty) return;

        final lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 100, int? page}) async {
        if (completer.isCanceled) return [];

        page = (page == null) ? 1 : page;

        List<Post> currentPosts = [];
        final int defaultSize = 100;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = (limit > checkSize) ? (page * (limit / checkSize)).floor() : page;

        final bool useLowerQuality = (_config.getConfig<bool>("use_lower_quality", defaultValue: false) == true);

        while (currentSize == checkSize) {
            if (completer.isCanceled) return [];

            final rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);

            if (completer.isCanceled) return [];

            currentSize = rawPosts.length;

            //rawPosts = _filterInvalidPosts(rawPosts);
            currentPosts.addAll(rawPosts.map((post) {
                if (useLowerQuality) post["use_lower_quality"] = true;
                
                return toPost(post);
            }));

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