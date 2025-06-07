import "dart:math";

import "package:async/async.dart";
import "package:nokufind/src/Utils/dtext_parser.dart";
import "package:nokufind/src/description.dart";
import 'package:trotter/trotter.dart';

import "subfinder.dart";
import "../API/danbooru_api.dart";
import "../Utils/utils.dart";
import "../post.dart";
import "../comment.dart";
import "../note.dart";

/// Converts DText-formatted strings into HTML.
///
/// Supports tags:
/// [b], [i], [u], [s], [tn], [spoiler], [nodtext], [code], [br],
/// links in the form "text":[url], [hr], [quote], [expand],
/// and basic table tags ([table], [thead], [tbody], [tr], [th], [td], [colgroup], [col]).

// Regexes created from [https://danbooru.donmai.us/wiki_pages/help:dtext]
final List<(RegExp, String)> _dtextReplacements = [
    (RegExp(r"\[b\](.*?)\[/b\]", dotAll: true), "<strong>\$1</strong>"),
    (RegExp(r"\[i\](.*?)\[/i\]", dotAll: true), "<em>\$1</em>"),
    (RegExp(r"\[u\](.*?)\[/u\]", dotAll: true), "<u>\$1</u>"),
    (RegExp(r"\[s\](.*?)\[/s\]", dotAll: true), "<s>\$1</s>"),
    (RegExp(r"\[tn\](.*?)\[/tn\]", dotAll: true), "<tn>\$1</tn>"),
    (RegExp(r"\[spoiler\](.*?)\[/spoiler\]", dotAll: true), "<spoiler>\$1</spoiler>"),
    (RegExp(r"\[nodtext\](.*?)\[/nodtext\]", dotAll: true), "<nodtext>\$1</nodtext>"),
    (RegExp(r"\[code\](.*?)\[/code\]", dotAll: true), "<code>\$1</code>"),
    (RegExp(r"\[br\]", multiLine: true), "<br>"),
    (RegExp(r"\[hr\]", multiLine: true), "<hr>"),
    (RegExp(r"\[quote\](.*?)\[/quote\]", dotAll: true), "<quote>\$1</quote>"),
    (RegExp(r"^h4\.\s*(.*?)$", multiLine: true), "<h4>\$1</h4>"),
    (RegExp(r"^h5\.\s*(.*?)$", multiLine: true), "<h5>\$1</h5>"),
    (RegExp(r"^h6\.\s*(.*?)$", multiLine: true), "<h6>\$1</h6>"),
    (RegExp(r"\[expand\](.*?)\[/expand\]", dotAll: true), "<expand>\$1</expand>"),
    (RegExp(r"\[table\]", multiLine: true), "<table>"),
    (RegExp(r"\[/table\]", multiLine: true), "</table>"),
    (RegExp(r"\[thead\]", multiLine: true), "<thead>"),
    (RegExp(r"\[/thead\]", multiLine: true), "</thead>"),
    (RegExp(r"\[tbody\]", multiLine: true), "<tbody>"),
    (RegExp(r"\[/tbody\]", multiLine: true), "</tbody>"),
    (RegExp(r"\[tr\]", multiLine: true), "<tr>"),
    (RegExp(r"\[/tr\]", multiLine: true), "</tr>"),
    (RegExp(r"\[th\]", multiLine: true), "<th>"),
    (RegExp(r"\[/th\]", multiLine: true), "</th>"),
    (RegExp(r"\[td\]", multiLine: true), "<td>"),
    (RegExp(r"\[/td\]", multiLine: true), "</td>"),
    (RegExp(r"\[colgroup\]", multiLine: true), "<colgroup>"),
    (RegExp(r"\[/colgroup\]", multiLine: true), "</colgroup>"),
    (RegExp(r"\[col\]", multiLine: true), "<col>"),
];

// Link pattern
final RegExp _linkPattern = RegExp(r'"(.*?)":\[(.*?)\]');

/// Expands $n, $& and $$ in [template] using the contents of [match].
String expandMatch(String template, Match match) {
    return template.replaceAllMapped(
        RegExp(r'\$(\d+|&|\$)'),
        (m) {
            final token = m.group(1);

            switch (token) {
                case null:  return m.group(0)!;
                case '&':   return match.group(0)!;
                case '\$':  return '\$';
                default:
                    // It's a capture group index.
                    final int? index = int.tryParse(token);

                    if (index != null && index <= match.groupCount) {
                        return match.group(index) ?? '';
                    }

                    return m.group(0)!;
            }
        },
    );
}

String convertDTextToHTML(String input) {
    return DTextParser.parse(input);

    /*var output = input;

    for (var entry in _dtextReplacements) {
        var regex = entry.$1;
        var replacement = entry.$2;

        output = output.replaceAllMapped(regex, (match) => expandMatch(replacement, match));
    }

    output = output.replaceAllMapped(_linkPattern, (match) => '<a href="${match[2]}">${match[1]}</a>');

    return output;*/
}

List<Map<String, dynamic>> _filterInvalidPosts(List<Map<String, dynamic>> posts) {
    return posts.where((element) => element.containsKey("md5") && element.containsKey("file_url")).toList();
}

List<Map<String, dynamic>> _filterInvalidComments(List<Map<String, dynamic>> comments) {
    return comments.where((element) => element.containsKey("body") && !element["is_deleted"]).toList();
}

class DanbooruFinder implements ISubfinder {
    static Post toPost(Map<String, dynamic> postData) {
        final String artistString = postData["tag_string_artist"] as String;
	    final String sourceString = postData["source"] as String;
        final String seriesString = postData["tag_string_copyright"] as String;
        final String characterString = postData["tag_string_character"] as String;

        Map<String, dynamic>? sampleData;

        if (postData.containsKey("media_asset")) {
            for (final item in (postData["media_asset"]["variants"] as List)) {
                final current = Map<String, dynamic>.from(item);

                if (current["type"] == "sample") {
                    sampleData = current;
                    break;
                }
            }
        }

        List<String> artists = [];

        final Set<Tag> tags = (postData["tag_string_general"] as String).split(" ").map((element) => Tag(element)).toSet();

        if (seriesString.isNotEmpty) {
            tags.addAll(
                seriesString.split(" ").map(
                    (element) => Tag(element, type: TagType.series)
                )
            );
        }

        if (characterString.isNotEmpty) {
            tags.addAll(
                characterString.split(" ").map(
                    (element) => Tag(element, type: TagType.character)
                )
            );
        }

        if (artistString.isNotEmpty) {
            artists = artistString.split(" ");
            tags.addAll(
                artists.map(
                    (element) => Tag(element, type: TagType.artist)
                )
            );
        }

        return Post(
            postID: postData["id"], 
            tags: tags.toList(), 
            sources: (sourceString.isEmpty) ? [] : sourceString.split(" "), 
            images: [postData["file_url"]],
            altImages: (sampleData != null) ? [sampleData["url"]] : null,
            authors: artists, 
            source: "danbooru", 
            preview: postData["preview_file_url"], 
            md5: [postData["md5"]], 
            rating: postData["rating"], 
            parentID: postData["parent_id"], 
            dimensions: [
                Dimensions(
                    postData["image_width"], 
                    postData["image_height"], 
                    alt: (sampleData != null) ? Dimensions(sampleData["width"], sampleData["height"]) : null
                )
            ], 
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
            body: convertDTextToHTML(commentData["body"]), 
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
            body: convertDTextToHTML(noteData["body"]), 
            source: "danbooru", 
            postID: noteData["post_id"]
        );
    }

    static Description toDescription(Map<String, dynamic> descriptionData) {
        print("orig: \"${descriptionData["original_description"]}\"");
        print("new: \"${convertDTextToHTML(descriptionData["original_description"])}\"");

        return Description(
            postID: descriptionData["post_id"],
            originalTitle: convertDTextToHTML(descriptionData["original_title"]), 
            originalDescription: convertDTextToHTML(descriptionData["original_description"]),
            translatedTitle: convertDTextToHTML(descriptionData["translated_title"]), 
            translatedDescription: convertDTextToHTML(descriptionData["translated_description"]),
            source: "danbooru",
            createdAt: DateTime.parse(descriptionData["created_at"])
        );
    }

    final DanbooruAPI _client = DanbooruAPI();
    final _config = SubfinderConfiguration();
    final List<CancelableCompleter> _completers = [];

    @override
    Future<List<Post>> searchPosts(String tags, {int limit = 200, int? page}) async {
        page = (page == null) ? 1 : page + 1;
        
        final completer = CancelableCompleter<List<Post>>(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final searchFuture = _getMultipleTags(tags, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    @override
    Future<List<Post>> searchPostsAdvanced(String tags, {String optionalTags = "", String blacklist = "", int limit = 200, int? page}) async {
        if (optionalTags.isEmpty && blacklist.isEmpty) {
            return searchPosts(tags, limit: limit, page: page);
        }

        page = (page == null) ? 1 : page + 1;

        final CancelableCompleter<List<Post>> completer = CancelableCompleter(
            onCancel: () {
                Nokulog.w("Search for \"$tags\" was cancelled.");
            }
        );

        final searchFuture = _getAdvancedPosts(tags, optionalTags, blacklist, completer, limit: limit, page: page);

        _completers.add(completer);

        completer.complete(searchFuture);

        return completer.operation.value;
    }

    @override
    Future<Post?> getPost(int postID) async {
        if (postID <= 0) return null;

        final rawPost = await _client.getPost(postID);

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

        return [for (final rawNote in rawNotes) toNote(rawNote)];
    }

    @override
    Future<Description?> getDescription(int postID) async {
        final rawDescription = await _client.getDescription(postID);

        return (rawDescription == null) ? null : toDescription(rawDescription);
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

    Future<List<Post>> _getMultipleTags(String tags, CancelableCompleter completer, {int limit = 200, int? page}) async {
        // First order of business it to check whether the operation has been cancelled.
        // If it has, no need to keep on doing stuff.
        if (completer.isCanceled) return [];

        // We parse the tags to turn them into a list that doesn't break quoted tags.
        // Example: hello "there people" -> ["hello", "there people"].
        final List<String> parsedTags = parseTags(tags.trim());
        
        // Danbooru's tag limit is 2. If the number of tags is 2 or less, there is no need to do all this convoluted stuff.
        if (parsedTags.length <= 2) {
            return _getAllPosts(tags, completer, limit: limit, page: page);
        }

        bool containsAll(Post post) {
            final Set<String> tagStrings = post.tags.map((element) => element.original).toSet();

            return tagStrings.containsAll(parsedTags);
        }

        List<Post> totalPosts = [];
        final List<String> tagCombinations = Combinations(2, parsedTags)().toSet().map((element) => element.join(" ")).toList();
        int currentPage = page ?? 1;

        Nokulog.i("tag combinations: $tagCombinations");
        
        while (totalPosts.length < limit) {
            final futures = tagCombinations.map((combination) {
                return _client.searchPosts(combination, page: currentPage);
            });

            final results = await Future.wait(futures);
            var minimumLength = 200;

            for (final result in results) {
                minimumLength = min(minimumLength, result.length);
                
                totalPosts.addAll(_filterInvalidPosts(result).map(toPost));
            }

            totalPosts = totalPosts.where(containsAll).toList();

            if (minimumLength < 200) {
                break;
            }

            currentPage++;
        }

        if (totalPosts.length > limit) {
            return totalPosts.sublist(0, limit);
        }

        return totalPosts;
    }

    Future<List<Post>> _getAdvancedPosts(String tags, String optionalTags, String blacklist, CancelableCompleter completer, {int limit = 100, int? page}) async {
        if (completer.isCanceled) return [];

        // If the page index is null, we begin by 0.
        page = (page == null) ? 0 : page;

        // We split the tags and the optional tags by spaces since the client doesn't use quotes.
        final List<String> splitTags = tags.trim().split(" ");
        final List<String> splitOptionalTags = (optionalTags.isNotEmpty) ? optionalTags.trim().split(" ") : [];
        final Iterable<String> splitBlacklist = (blacklist.isNotEmpty) ? blacklist.trim().split(" ") : [];
        final List<String> queries = [];

        for (final optionalTag in splitOptionalTags) {
            queries.add(
                [...splitTags, optionalTag]  // We merge the tags, one optional tag, and the blacklisted tags.
                .where((element) => element.isNotEmpty)         // We remove any empty strings.
                .join(" ")                                      // We join them into a singular empty string.
            );
        }

        Nokulog.i("queries: ${queries.join("\n")}");

        final int postsPerQuery = (limit / queries.length).ceil();

        List<Post> currentPosts = [];
        final int defaultSize = 100;
        final int checkSize = min(min(defaultSize, limit), postsPerQuery);
        int currentSize = checkSize;
        int currentPage = (limit > checkSize) ? (page * (limit / checkSize)).floor() : page;
        final Map<String, bool> queryIsExhausted = {for (final query in queries) query: false};

        while (currentSize == checkSize) {
            if (completer.isCanceled) return [];

            if (queryIsExhausted.values.every((value) => value)) {
                break;
            }

            final futures = queries.where((element) => !queryIsExhausted[element]!,).map((query) {
                return () async {
                    if (completer.isCanceled) return <Post>[];

                    final results = await _getMultipleTags(query, completer, limit: checkSize, page: currentPage);

                    if (results.length < checkSize) {
                        queryIsExhausted[query] = true;
                    }

                    return results;
                }();
            });

            if (completer.isCanceled) return [];

            final results = await Future.wait(futures);

            if (results.isEmpty) {
                break;
            }
            
            for (final result in results) {
                currentPosts.addAll(result);
                currentSize = max(currentSize, result.length);
            }

            currentPosts.removeWhere((post) {
                final mapped = post.tags.map((element) => element.original).toSet();
                for (final tag in splitBlacklist) {
                    if (mapped.contains(tag)) {
                        return true;
                    }
                }

                return false;
            });

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

    Future<List<Post>> _getAllPosts(String tags, CancelableCompleter completer, {int limit = 200, int? page}) async {
        if (completer.isCanceled) return [];

        page = page ?? 1;

        List<Post> currentPosts = [];
        final int defaultSize = 200;
        final int checkSize = min(defaultSize, limit);
        int currentSize = checkSize;
        int currentPage = page;

        if (limit <= defaultSize) {
            final rawPosts = await _client.searchPosts(tags, limit: checkSize, page: currentPage);
            if (completer.isCanceled) return [];
            return _filterInvalidPosts(rawPosts).map(toPost).toList();
        }

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
