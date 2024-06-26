

import "dart:math";

import "subfinder.dart";
import "../Utils/rule34_api.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";


/*List<Map<String, dynamic>> _filterInvalidPosts(List<Map<String, dynamic>> posts) {
    return posts.where((element) => element.containsKey("md5") && element.containsKey("file_url")).toList();
}

List<Map<String, dynamic>> _filterInvalidComments(List<Map<String, dynamic>> comments) {
    return comments.where((element) => element.containsKey("body") && !element["is_deleted"]).toList();
}*/

class Rule34Finder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        return Post(
            postID: postData["id"], 
            tags: List<String>.from(postData["tags"]), 
            sources: List<String>.from(postData["sources"]), 
            images: [postData["file_url"]], 
            authors: List<String>.from(postData["authors"]), //(postData["tag_string_artist"] as String).split(" "), 
            source: "rule34", 
            preview: postData["preview_url"], 
            md5: [postData["hash"]], 
            rating: postData["rating"], 
            parentID: (postData["parent_id"] != 0) ? postData["parent_id"] : null, 
            dimensions: [[postData["width"], postData["height"]]], 
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
            body: commentData["body"], 
            source: "rule34",
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
            source: "rule34", 
            postID: noteData["post_id"]
        );
    }

    final Rule34API _client;
    final _config = SubfinderConfiguration();

    Rule34Finder() : _client = Rule34API();

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 1000, int? page}) async {
        page = (page == null) ? 0 : page - 1;
        page = (page < 0) ? 0 : page;

        return await _getAllPosts(tags, limit: limit, page: page);
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        var rawPost = await _client.getPost(postID);

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 0 : page;

        var rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        //rawComments = _filterInvalidComments(rawComments);

        return [for (var rawComment in rawComments) toComment(rawComment)];
    }

    @override
    Future<Comment?> getComment(int commentID, {int? postID}) async {
        if (postID == null) return null;

        var rawComment = await _client.getComment(commentID, postID);

        return (rawComment != null) ? toComment(rawComment) : null;
    }

    @override
    Future<List<Note>> getNotes(int postID) async {
        var rawNotes = await _client.getNotes(postID);

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

    Future<List<Post>> _getAllPosts(String tags, {int limit = 1000, int? page}) async {
        page = (page == null) ? 0 : page;

        List<Post> currentPosts = [];
        int defaultSize = 1000;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            var rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);

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