

import "dart:math";

import "subfinder.dart";
import "../Utils/nhentai_api.dart";
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

        return Post(
            postID: postData["id"], 
            tags: List<String>.from(postData["tags"]), 
            sources: ["https://nhentai.net/g/${postData['id']}"], 
            images: List<String>.from(postData["images"]), 
            authors: List<String>.from(postData["authors"]), //(postData["tag_string_artist"] as String).split(" "), 
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
            source: "nhentai",
            createdAt: commentData["created_at"] as DateTime
        );
    }

    static Note toNote(Map<String, dynamic> noteData) {
        throw Exception("NHentai has no notes.");
    }

    late NHentaiAPI _client;

    NHentaiFinder(String cfClearance) {
        _client = NHentaiAPI(cfClearance);
    }

    final _config = SubfinderConfiguration();

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 25, int? page}) async {
        page = (page == null) ? 1 : page;
        page = (page <= 0) ? 1 : page;

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
        return [];
    }

    @override
    Future<Post?> postGetParent(Post post) async {
        return null;
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        return [];
    }

    Future<List<Post>> _getAllPosts(String tags, {int limit = 25, int? page}) async {
        page = (page == null) ? 0 : page;

        List<Post> currentPosts = [];
        int defaultSize = 25;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            var rawPosts = await _client.searchPosts(tags, limit: limit, page: currentPage);

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