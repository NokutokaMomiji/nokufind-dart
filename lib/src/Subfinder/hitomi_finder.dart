

import "package:async/async.dart";

import "subfinder.dart";
import "../Utils/hitomi_api.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";

class HitomiFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        return Post(
            postID: postData["postID"], 
            tags: postData["tags"], 
            sources: [], 
            images: postData["images"], 
            authors: postData["artists"],
            source: "hitomi", 
            preview: postData["preview"], 
            md5: postData["hashes"],
            rating: "e", 
            parentID: null, 
            dimensions: postData["dimensions"], 
            poster: "Unknown",
            posterID: null, 
            title: postData["title"]
        )..setHeaders({"Referer": "https://hitomi.la"});
    }

    static Comment toComment(Map<String, dynamic> commentData) {
        throw Exception("Hitomi has no concept of comments. Do not use \"toComment\".");
    }

    static Note toNote(Map<String, dynamic> noteData) {
        throw Exception("Hitomi has no concept of notes. Do not use \"toNote\".");
    }

    final HitomiAPI _client;
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    HitomiFinder({bool preferWebp = false}) : _client = HitomiAPI(preferWebp: preferWebp);

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;
        
        await _client.configureCommon();

        var rawPosts = await _client.searchPosts(tags, limit: limit, page: page);

        return rawPosts.map(toPost).toList();
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        await _client.configureCommon();

        var rawPost = await _client.getPost(postID);

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

        var lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }
    
    bool get preferWebp => _client.preferWebp;
    set preferWebp(bool value) {
        _client.preferWebp = value;
    }

    @override
    SubfinderConfiguration get configuration => _config;
}