

import "dart:math";

import "subfinder.dart";
import "../Utils/mangadex_api.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";


/*List<Map<String, dynamic>> _filterInvalidPosts(List<Map<String, dynamic>> posts) {
    return posts.where((element) => element.containsKey("md5") && element.containsKey("file_url")).toList();
}

List<Map<String, dynamic>> _filterInvalidComments(List<Map<String, dynamic>> comments) {
    return comments.where((element) => element.containsKey("body") && !element["is_deleted"]).toList();
}*/

class MangadexFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        return Post(
            postID: postData["post_id"],
            tags: postData["tags"], 
            sources: List<String>.from(postData["sources"]), 
            images: List<String>.from(postData["images"]), 
            authors: List<String>.from(postData["authors"]), //(postData["tag_string_artist"] as String).split(" "), 
            source: "mangadex", 
            preview: postData["preview"], 
            md5: [], 
            rating: postData["rating"], 
            parentID: postData["parent_id"], 
            dimensions: List<List<int>>.from(postData["dimensions"]), 
            poster: postData["owner"],
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

    final MangadexAPI _client;
    final _config = SubfinderConfiguration();

    MangadexFinder() : _client = MangadexAPI();

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 0 : page - 1;
        page = (page < 0) ? 0 : page;

        return await _getAllPosts(tags, limit: limit, page: page);
    }

    @override
    Future<Post?> getPost(dynamic postID) async {
        if (postID is! String) {
            throw ArgumentError.value(postID, "postID", "postID should be a string UUID");
        }

        var rawPost = await _client.getPost(postID);

        return (rawPost != null) ? toPost(rawPost) : null;
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 0 : page;

        return [];

        /*var rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        //rawComments = _filterInvalidComments(rawComments);

        return [for (var rawComment in rawComments) toComment(rawComment)];*/
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
    Future<Post?> postGetParent(Post post) async {
        if (post.parentID == null) {
            return null;
        }

        return post.setParent(await getPost(post.parentID as int));
    }

    @override
    Future<List<Post>> postGetChildren(Post post) async {
        var rawChildren = await _client.postGetChildren(post.postUID);

        if (rawChildren.isEmpty) return [];

        List<Post> children = [for (var child in rawChildren) toPost(child)];
        
        return post.setChildren(children);
    }

    Future<List<Post>> _getAllPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 0 : page;

        List<Post> currentPosts = [];
        int defaultSize = 100;
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