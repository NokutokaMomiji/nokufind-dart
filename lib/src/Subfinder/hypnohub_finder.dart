

import "dart:math";

import "package:async/async.dart";
import "package:nokufind/src/Utils/dtext_parser.dart";
import "package:nokufind/src/description.dart";

import "subfinder.dart";
import "../API/hypnohub_api.dart";
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

class HypnohubFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        String? sampleURL;
        Dimensions? sampleDimensions;
        
        if (postData["sample"] == 1) {
            sampleURL = postData["sample_url"];
            sampleDimensions = Dimensions(postData["sample_width"], postData["sample_height"]);
        }

        return Post(
            postID: postData["id"], 
            tags: List<String>.from(postData["tags"]), 
            sources: List<String>.from(postData["sources"]), 
            images: [postData["file_url"]],
            altImages: (sampleURL != null) ? [sampleURL] : null,
            authors: List<String>.from(postData["authors"]), //(postData["tag_string_artist"] as String).split(" "), 
            source: "hypnohub", 
            preview: postData["preview_url"], 
            md5: [postData["hash"]], 
            rating: postData["rating"], 
            parentID: (postData["parent_id"] != 0) ? postData["parent_id"] : null, 
            dimensions: [
                Dimensions(postData["width"], postData["height"], alt: sampleDimensions)
            ], 
            poster: postData["owner"],
            posterID: null, 
            title: null
        );
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        return Comment(
            commentID: commentData["id"], 
            postID: commentData["post_id"], 
            creatorID: commentData["creator_id"],
            creator: commentData["creator"] ?? "User ${commentData['creator_id']}",
            body: DTextParser.parse(commentData["body"]), 
            source: "hypnohub",
            createdAt: commentData["created_at"] as DateTime
        );
    }

    static Note toNote(Map<String, dynamic> noteData) {
        return Note(
            noteID: noteData["id"], 
            createdAt: noteData["created_at"], 
            x: noteData["x"], 
            y: noteData["y"], 
            width: noteData["width"], 
            height: noteData["height"], 
            body: noteData["body"], 
            source: "hypnohub", 
            postID: noteData["post_id"]
        );
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        throw UnimplementedError("Hypnohub has no descriptions. Do not use toDescription.");
    }

    final HypnohubApi _client;
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    HypnohubFinder() : _client = HypnohubApi();

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 1000, int? page}) async {
        page = (page == null) ? 0 : page;
        page = (page < 0) ? 0 : page;

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
        final baseTags = tags.trim().split(" ");
        final optionalTagList = (optionalTags.isNotEmpty) ? optionalTags.trim().split(" ") : <String>[];
        final blacklistTags = (blacklist.isNotEmpty) ? blacklist.trim().split(" ").map((element) => "-$element") : <String>[];

        final optionalTagString = (optionalTagList.isNotEmpty) ? " ( ${optionalTagList.join(" ~ ")} )" : "";
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
        final rawNotes = await _client.getNotes(postID);

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

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 1000, int? page}) async {
        if (completer.isCanceled) return [];

        page = (page == null) ? 0 : page;

        List<Post> currentPosts = [];
        final int defaultSize = 1000;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = (limit > checkSize) ? (page * (limit / checkSize)).floor() : page;

        while (currentSize == checkSize) {
            if (completer.isCanceled) return [];

            final rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);

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
    
      @override
      SubfinderConfiguration get configuration => _config;
}