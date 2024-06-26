

import "dart:math";

import "subfinder.dart";
import "../Utils/yandere_api.dart";
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
        int width = postData["width"];
        int height = postData["height"];
        String imageURL = postData["file_url"];

        if (postData.containsKey("use_lower_quality")) {
            width = postData["jpeg_width"];
            height = postData["jpeg_height"];
            imageURL = postData["jpeg_url"];
        }

        return Post(
            postID: postData["id"], 
            tags: (postData["tags"] as String).split(" "), 
            sources: (postData["source"] as String).split(" "), 
            images: [imageURL], 
            authors: [], //(postData["tag_string_artist"] as String).split(" "), 
            source: "yande.re", 
            preview: postData["preview_url"], 
            md5: [postData["md5"]], 
            rating: postData["rating"], 
            parentID: postData["parent_id"], 
            dimensions: [[width, height]], 
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

    final YandereAPI _client = YandereAPI();
    final _config = SubfinderConfiguration();

    YandereFinder() {
        _config.setProperty("use_lower_quality", false);
    }

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;

        return await _getAllPosts(tags, limit: limit, page: page);
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        var rawPost = await _client.getPost(postID);

        if (_config.getConfig<bool>("use_lower_quality", defaultValue: false) == true) {
            rawPost?["use_lower_quality"] = true;
        }

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;

        var rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        //rawComments = _filterInvalidComments(rawComments);

        return [for (var rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        var rawComment = await _client.getComment(commentID);

        return (rawComment != null) ? toComment(rawComment) : null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        var rawNotes = await _client.getNotes(postID);

        if (rawNotes == null) {
            return List<Note>.empty(growable: true);
        }

        return [for (var rawNote in rawNotes) toNote(rawNote)];
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

    Future<List<Post>> _getAllPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;

        List<Post> currentPosts = [];
        int defaultSize = 100;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        bool useLowerQuality = (_config.getConfig<bool>("use_lower_quality", defaultValue: false) == true);

        while (currentSize == checkSize) {
            var rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);

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