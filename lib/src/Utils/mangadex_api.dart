import "dart:async";
import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:html/parser.dart";
import "package:image_size_getter/image_size_getter.dart";
import "package:intl/intl.dart";

import "../Utils/utils.dart";

class MangadexTag {
    String _id = "";
    String _name = "";

    MangadexTag(Map<String, dynamic> rawData) {
        _id = rawData["id"]!;
        _name = rawData["attributes"]!["name"]!["en"];
    }

    String get id => _id;
    String get name => _name;

    static Map<String, MangadexTag> generate(Map<String, dynamic> response) {
        Map<String, MangadexTag> finalMap = {};

        var dataList = List<Map<String, dynamic>>.from(response["data"]!);

        for (var item in dataList) {
            var newTag = MangadexTag(item);
            finalMap[newTag.name.toLowerCase()] = newTag;
        }

        return finalMap;
    }
}

class MangadexAPI {
    static const String _url = "https://api.mangadex.org/";
    static const String userAgent = "Mozilla/5.0 (compatible; nokufind-dart/1.0.0)";
    static const Map<String, String> headers = {
        "User-Agent": userAgent
    };
    static const List<int> idLengths = [
        10,
        5,
        5,
        5,
        15
    ];
    static Map<String, MangadexTag> _tags = {};

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: Duration(seconds: 15)));
    final _dateFormat = DateFormat("EEE MMM dd HH:mm:ss yyyy");

    bool dataSaver = false;

    MangadexAPI() {
        _client.options.headers = headers;

        addSmartRetry(_client);
        _fetchTagsIfNone();
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        limit = limit.clamp(1, 100);

        await _fetchTagsIfNone();

        List<String> tagUUID = await _getTagIdentifiers(tags);

        Map<String, dynamic> params = {
            "includes[]": ["author", "artist", "cover_art", "creator"],
            "limit": limit,
        };

        if (tagUUID.isEmpty) {
            params["title"] = tags;
        } else {
            params["includedTags[]"] = tagUUID;
            print("Settings includedTags[] to $tagUUID");
        }

        try {
            var results = Map<String, dynamic>.from(await _makeRequest("manga", params: params));
            var posts = List<Map<String, dynamic>>.from(results["data"]);
            
            Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(5));

            for (var post in posts) {
                executor.scheduleTask(() async => await _extractPostData(post));
            }

            var finishedPosts = await executor.join(withWaiting: true);
            return List<Map<String, dynamic>>.from(finishedPosts);
        } on DioException {
            return List<Map<String, dynamic>>.empty(growable: true);
        }
    }

    Future<Map<String, dynamic>?> getPost(String postID) async {
        try {

            var result = await _makeRequest("manga/$postID", params: {
                "includes[]": ["author", "artist", "cover_art", "creator"]
            });

            if (result["result"] != "ok") {
                Nokulog.logger.e(result);
                return null;
            }

            return _extractPostData(result["data"]);
        } catch (e) {
            Nokulog.logger.e(e);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;
        
        Map<String, String> params = {
            "limit": limit.toString(),
            "page": page.toString()
        };

        String url = (postID == null) ? "${_url}comment" : "${_url}post/show/$postID";

        Response<String> response = await _client.get(Uri.parse(url).toString(), queryParameters: params);
        var document = parse(response.data!);
        var rawComments = document.getElementsByClassName("comment avatar-container");

        List<Map<String, dynamic>> results = [];

        for (var element in rawComments) {
            var innerElement = parse(element.outerHtml);
            var dateObject = innerElement.getElementsByClassName("date").first;
            var authorObject = innerElement.getElementsByClassName("author").first.children.first.children.first;
            var avatar = innerElement.getElementsByClassName("avatar");

            Map<String, dynamic> comment = {
                "id": int.parse(element.id.replaceAll("c", "")),
                "post_id": int.parse(dateObject.children.first.attributes["href"]!.split("/").last.split("#").first),
                "creator": authorObject.innerHtml.trim(),
                "creator_id": int.parse(authorObject.attributes["href"]!.split("/").last),
                "creator_avatar": (avatar.isNotEmpty) ? avatar.first.attributes["src"] : null,
                "body": innerElement.getElementsByClassName("body").first.innerHtml.trim(),
                "created_at": _dateFormat.parseLoose((dateObject.attributes["title"] as String).replaceAll("Posted at", "").trim())
            };

            results.add(comment);
        }

        return results;
    }

    Future<Map<String, dynamic>?> getComment(int commentID) async {
        if (commentID <= 0) {
            return null;
        }
        
        Map<String, String> params = {
            "id": commentID.toString()
        };

        try {
            return await _makeRequest("comment/show.json", params: params) as Map<String, dynamic>;
        } on DioException {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>?> getNotes(int postID) async {
        if (postID <= 0) {
            return null;
        }

        try {
            List<dynamic> results = await _makeRequest("note.json", params: { "post_id": postID.toString() }) as List<dynamic>;
        
            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } on DioException {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> postGetChildren(String uid) async {
        // Get chapters from feed.
        // (?) Filter out other language chapters.
        // Sort per chapter index.
        // Get chapter urls

        List<Map<String, dynamic>> children = [];

        try {
            Map<String, dynamic> results = await _makeRequest("manga/$uid/feed", params: {
                "includes[]": ["manga", "user"]
            });

            if (results["result"] != "ok") {
                Nokulog.logger.e(results);
                return children;
            }

            Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(5));

            for (Map<String, dynamic> item in results["data"]) {
                if (item["type"] != "chapter") continue;

                executor.scheduleTask(() async {
                    Map<String, dynamic> chapterImages = await _makeRequest("at-home/server/${item["id"]}");

                    String baseUrl = chapterImages["baseUrl"];
                    String chapterHash = chapterImages["chapter"]["hash"];
                    String dataIndex = (dataSaver) ? "dataSaver" : "data";
                    String dataPath = (dataSaver) ? "data-saver": "data";
                    
                    List<String> imageFilenames = List<String>.from(chapterImages["chapter"][dataIndex]);
                    String template = "$baseUrl/$dataPath/$chapterHash";

                    Map<String, dynamic> rawPost = item["relationships"][1];
                    Map<String, dynamic> attributes = rawPost["attributes"];

                    return <String, dynamic>{
                        "post_id": rawPost["id"],
                        "tags": [
                            for (var tag in (attributes["tags"] as List))
                            tag["attributes"]["name"]["en"] as String
                        ],
                        "sources": [attributes["links"]["raw"]],
                        "images": [for (var filename in imageFilenames) "$template/$filename"],
                        "authors": [],
                        "title": "${attributes["title"]["en"]} - Chapter ${item["attributes"]["chapter"]} (${item["attributes"]["translatedLanguage"]})",
                        "preview": "$baseUrl/data-saver/$chapterHash/${chapterImages["chapter"]["dataSaver"][0]}",
                        "dimensions": [],
                        "parent_id": null,
                        "rating": attributes["contentRating"],
                        "owner": item["relationships"][2]["attributes"]["username"]
                    };
                });
            }

            children = List<Map<String, dynamic>>.from(await executor.join(withWaiting: true));
            await executor.close();
            return children;

        } catch(e) {
            return children;
        }
    }

    Future<int> _convertUID(String uid) async {
        return -1;

        /*List<String> rawHexParts = uid.split("-");
        List<int> rawInts = [for (var part in rawHexParts) int.parse(part, radix: 16)];
        String constructedInt = "1";

        for (var i = 0; i < rawInts.length; i++) {
            int rawInt = rawInts[i];
            int currentLength = idLengths[i];
            constructedInt += rawInt.toString().padLeft(currentLength, "0");
        }

        return int.parse(constructedInt);*/
    }

    Future<void> _fetchTagsIfNone() async {
        if (_tags.isNotEmpty) return;

        try {
            var response = await _makeRequest("manga/tag");
            MangadexAPI._tags = MangadexTag.generate(response);
        } catch (e) {
            Nokulog.logger.e("manga/tag");
            Nokulog.logger.e(e);
        }
    }

    Future<Map<String, dynamic>> _extractPostData(Map<String, dynamic> rawPost) async {
        //print(rawPost);
        var relationships = List<Map<String, dynamic>>.from(rawPost["relationships"]);
        String coverArtData = "";
        String owner = "";
        List<String> authors = [];

        for (var relationship in relationships) {
            if (relationship["type"] == "author" || relationship["type"] == "artist") {
                authors.add(relationship["attributes"]["name"]);
                continue;
            }

            if (relationship["type"] == "cover_art" && coverArtData.isEmpty) {
                coverArtData = relationship["attributes"]["fileName"];
                continue;
            }

            if (relationship["type"] == "creator" && owner.isEmpty) {
                owner = relationship["attributes"]["username"];
            }
        }

        String image = "https://uploads.mangadex.org/covers/${rawPost["id"]}/$coverArtData";
        
        ResponseType previous = _client.options.responseType;
        _client.options.responseType = ResponseType.bytes;

        Response imageRequest = await _client.get(image);
        Size imageSize = ImageSizeGetter.getSize(MemoryInput(imageRequest.data));

        _client.options.responseType = previous;

        Map<String, dynamic> attributes = rawPost["attributes"];

        return <String, dynamic>{
            "post_id": rawPost["id"],
            "tags": [
                for (var tag in (attributes["tags"] as List))
                tag["attributes"]["name"]["en"] as String
            ],
            "sources": [attributes["links"]["raw"]],
            "images": [image],
            "authors": authors,
            "title": attributes["title"]["en"],
            "preview": image,
            "dimensions": [[imageSize.width, imageSize.height]],
            "parent_id": null,
            "rating": attributes["contentRating"],
            "owner": owner
        };
    }

    Future<List<String>> _getTagIdentifiers(String query) async {
        List<String> splitQuery = parseTags(query);
        List<String> ids = [];

        for (int i = 0; i < splitQuery.length; i++) {
            String current = splitQuery[i].toLowerCase();
            print(current);

            // First we check if the current possible tag is actually a single tag.
            if (_tags.containsKey(current)) {
                Nokulog.logger.d("Found $current!");
                ids.add(_tags[current]!.id);
                continue;
            }

            String? next = get(splitQuery, ++i, defaultValue: null);

            // Otherwise, we check if the current tag and the next tag make a valid tag.
            if (next == null) {
                return ids;
            }

            String possible = "$current $next";

            if (!_tags.containsKey(possible)) continue;

            ids.add(_tags[possible]!.id);
        }

        print("ids: $ids");

        return ids;
    }

    Future<dynamic> _makeRequest(String file, {Map<String, dynamic>? params}) async {
        //String paramString = (params != null) ? mapToPairedString(params) : "";
        Uri requestURL = Uri.parse("$_url$file");

        Response<String> response = await _client.get(requestURL.toString(), queryParameters: params);

        Nokulog.logger.d(response.requestOptions.uri.toString());

        if (response.data == null) {
            throw DioException(
                requestOptions: response.requestOptions,
                response: response,
                message: "Response data was null"
            );
        }

        return jsonDecode(response.data!);
    }
}