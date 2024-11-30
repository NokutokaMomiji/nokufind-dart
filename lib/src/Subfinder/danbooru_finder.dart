import "dart:math";

import "package:async/async.dart";
import 'package:trotter/trotter.dart';

import "subfinder.dart";
import "../Utils/danbooru_api.dart";
import "../Utils/utils.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";


List<Map<String, dynamic>> _filterInvalidPosts(List<Map<String, dynamic>> posts) {
    return posts.where((element) => element.containsKey("md5") && element.containsKey("file_url")).toList();
}

List<Map<String, dynamic>> _filterInvalidComments(List<Map<String, dynamic>> comments) {
    return comments.where((element) => element.containsKey("body") && !element["is_deleted"]).toList();
}

class DanbooruFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        String artistString = postData["tag_string_artist"] as String;
	    String sourceString = postData["source"] as String;

        return Post(
            postID: postData["id"], 
            tags: (postData["tag_string"] as String).split(" "), 
            sources: (sourceString.isEmpty) ? [] : sourceString.split(" "), 
            images: [postData["file_url"]], 
            authors: (artistString.isEmpty) ? [] : artistString.split(" "), 
            source: "danbooru", 
            preview: postData["preview_file_url"], 
            md5: [postData["md5"]], 
            rating: postData["rating"], 
            parentID: postData["parent_id"], 
            dimensions: [[postData["image_width"], postData["image_height"]]], 
            poster: postData["author"] ?? "User ${postData['uploader_id']}",
            posterID: postData["uploader_id"], 
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
            source: "danbooru", 
            createdAt: DateTime.parse(commentData["created_at"])
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
            source: "danbooru", 
            postID: noteData["post_id"]
        );
    }

    final DanbooruAPI _client = DanbooruAPI();
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 200, int? page}) async {
        page = (page == null) ? 1 : page;
        
        CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        var searchFuture = _getMultipleTags(tags, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        var rawPost = await _client.getPost(postID);

        if (rawPost == null) {
            return null;
        }

        if (!rawPost.containsKey("md5") || !rawPost.containsKey("file_url")) {
            return null;
        }

        return toPost(rawPost);
    }

    @override
    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page}) async {
        page = (page == null) ? 1 : page;

        var rawComments = await _client.searchComments(postID: postID, limit: limit, page: page);

        rawComments = _filterInvalidComments(rawComments);

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

    @override
    Future<void> cancelLastSearch() async {
        if (_completers.isEmpty) return;

        var lastCompleter = _completers.removeLast();
        lastCompleter.operation.cancel();
    }

    Future<List<Post>> _getMultipleTags(String tags, CancelableCompleter completer, {int limit = 200, int? page}) async {
        // First order of business it to check whether the operation has been cancelled.
        // If it has, no need to keep on doing stuff.
        if (completer.isCanceled) return [];

        // We parse the tags to turn them into a list that doesn't break quoted tags.
        // Example: hello "there people" -> ["hello", "there people"].
        List<String> parsedTags = parseTags(tags);
        
        // Danbooru's tag limit is 2. If the number of tags is 2 or less, there is no need to do all this convoluted stuff.
        if (parsedTags.length <= 2) {
            return _getAllPosts(tags, completer, limit: limit, page: page);
        }

        List<Post> totalPosts = [];

        // First we check if there are any "or" keywords on the tags so that we can get the union of the two tag combinations.
        for (int i = 0; i < parsedTags.length; i++) {
            var currentTag = parsedTags[i];

            if (currentTag == "or") {
                List<Post> s1 = [];
                List<Post> s2 = [];
                String? prevTags = get(parsedTags, i - 1);
                String? nextTags = get(parsedTags, i + 1);
            
                if (prevTags != null) {
                    s1 = await _getMultipleTags(trim(prevTags, "()"), completer, limit: limit, page: page);
                    if (completer.isCanceled) return [];
                }

                if (nextTags != null) {
                    s2 = await _getMultipleTags(trim(nextTags, "()"), completer, limit: limit, page: page);
                    if (completer.isCanceled) return [];
                }

                return [...s1, ...s2];
            } else if (currentTag.contains("or")) {
                String? nextTags = get(parsedTags, i + 1);
                if (nextTags != null) {
                    return await _getMultipleTags(trim(nextTags, "()"), completer, limit: limit, page: page);
                }
            }
        }

        // If we got here, we have no "or"s. 

        List<String> totalCombinations = [];

        if (parsedTags.length % 2 == 0) {
            // We have an even number of tags. So we create pairs of two.
            for (int i = 0; i < parsedTags.length; i += 2) {
                totalCombinations.add(parsedTags.sublist(i, i + 2).join(" "));
            }
        } else {
            // We have an uneven amount of tags, so we create the least amount of combinations for pairs of two.
            totalCombinations = Combinations(2, parsedTags)().map((e) => e.join(" ")).toList();
            Nokulog.d("total combinations: $totalCombinations");
        }

        int startPage = page ?? 1;
        List<Future<List<Post>>> postFutures = [];

        while (totalPosts.length < limit) {
            for (String combination in totalCombinations) {
                Nokulog.d(combination);

                postFutures.add(_getAllPosts(combination, completer, limit: limit, page: startPage));
            }

            var postResults = await Future.wait(postFutures);

            for (var currentPosts in postResults) {
                // Since no posts were found with a given combination, we know that there will not be any post that contains all given tags.
                if (currentPosts.isEmpty) {
                    return [];
                }

                totalPosts.addAll(currentPosts);
            }

            postFutures.clear();
            startPage++;
        }

        List<Post> filteredPosts = totalPosts.where((element) {
            for (String tag in parsedTags) {
                if (tag.startsWith("rating:") || tag.startsWith("has:")) continue;
                for (Tag tagObject in element.tags) {
                    if (tagObject.contains(tag)) {
                        return true;
                    }
                }
                return false;
            }
            
            return true;
        }).toList();

        if (filteredPosts.length > limit) {
            return filteredPosts.sublist(0, limit);
        }

        return filteredPosts;
    }

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 200, int? page}) async {
        if (completer.isCanceled) return [];

        page = (page == null) ? 1 : page;

        List<Post> currentPosts = [];
        int defaultSize = 200;
        int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        while (currentSize == checkSize) {
            var rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);
            if (completer.isCanceled) return [];

            Nokulog.d("[nokufind.DanbooruFinder]: Found ${rawPosts.length}.");

            currentSize = rawPosts.length;

            rawPosts = _filterInvalidPosts(rawPosts);
            Nokulog.d("[nokufind.DanbooruFinder]: After filtering, ${rawPosts.length} remained.");
            currentPosts.addAll(rawPosts.map(toPost));

            Nokulog.d("[nokufind.DanbooruFinder]: Currently at ${currentPosts.length} posts.");

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
