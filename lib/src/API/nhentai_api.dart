import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:html/dom.dart";
//import "package:intl/intl.dart";

import "../Utils/utils.dart";

enum ImageType {
    cover,
    thumbnail,
    image
}

class NHentaiAPI {
    static const String _url = "https://nhentai.net/api/";
    static const String _siteUrl = "https://nhentai.net/";
    static const String _imageUrl = "https://i1.nhentai.net/galleries/";
    static const String _avatarUrl = "https://i5.nhentai.net/";
    static const String _tinyImageUrl = "https://t1.nhentai.net/galleries/";
    static const String _randomUrl = "https://nhentai.net/random/";
    static const String _userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 OPR/116.0.0.0";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    //final _dateFormat = DateFormat("yyyy-MM-dd HH:mm:ss");
    
    final String cfClearance;
    final String csrfToken;
    final String sessionAffinity;

    Map<String, String> defaultHeaders = {};

    NHentaiAPI(this.cfClearance, this.csrfToken, this.sessionAffinity) {
        defaultHeaders["User-Agent"] = _userAgent;
        defaultHeaders["Accept"] = "*/*";
        defaultHeaders["Connection"] = "keep-alive";
        defaultHeaders["Cookie"] = "cf_clearance=$cfClearance; csrftoken=$csrfToken; session-affinity=$sessionAffinity";
        _client.options.headers = defaultHeaders;
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 25, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 25;
        
        final Map<String, String> params = {
            "page": page.toString(),
        };

        if (tags.isNotEmpty) {
            params["q"] = tags;//.replaceAll(" ", "+");
        }

        int innerPage = page;
        final List<Map<String, dynamic>> rawPosts = [];
        final String requestPart = (tags.isEmpty) ? _siteUrl : "${_siteUrl}search/";
        Response<String> response;
        try {
            while (rawPosts.length < limit) {
                params["page"] = innerPage.toString();

                final String paramString = mapToPairedString(params);
                final Uri url = Uri.parse("$requestPart?$paramString");

                Nokulog.d(url);
                
                response = await _client.get(url.toString());

                final Document document = Document.html(response.data!);

                //Element? searchResultsContainer = document.querySelector("div .container");

                //if (searchResultsContainer == null) {
                //    Nokulog.e("No search results container found.");
                //    return rawPosts;
                //}
                
                final List<Element> searchResults = document.getElementsByClassName("gallery");

                if (searchResults.isEmpty) {
                    Nokulog.e("No search results.");
                    return rawPosts;
                }
                final List<int> postIDs = [];

                Nokulog.d("Found ${searchResults.length} results.");

                for (final searchResult in searchResults) {
                    final Document results = Document.html(searchResult.outerHtml);
                    final tagResults = results.querySelector("a.cover");
                    if (tagResults == null) {
                        continue;
                    }
                
                    //Nokulog.d(tagResults.outerHtml);
                    //Nokulog.d(tagResults.attributes["href"]);
                    final String? tempID = tagResults.attributes["href"]?.split("/")[2];
                
                    if (tempID == null) {
                        continue;
                    }

                    postIDs.add(int.parse(tempID));
                }

                final Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(5));

                for (final int postID in postIDs) {
                    executor.scheduleTask(() async {
                        final post = await getPost(postID);
                        if (post == null) return;
                        rawPosts.add(post);
                    });
                }

                await executor.join(withWaiting: true);
                await executor.close();

                if (rawPosts.length > limit) {
                    break;
                }

                innerPage += 1;
            }

            if (rawPosts.length > limit) {
                return rawPosts.sublist(0, limit);
            }

            return rawPosts;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch posts matching \"$tags\".\n${_client.options.headers}", error: e, stackTrace: stackTrace);
            return rawPosts;
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        try {
            //Nokulog.d("Getting post with id $postID");
            final Map<String, dynamic> result = await _makeRequest("${_url}gallery/$postID") as Map<String, dynamic>;

            if (result.containsKey("error")) {
                Nokulog.e("NHentai result: $result");
                return null;
            }

            final Map<String, dynamic> myResult = {};

            myResult["id"] = result["id"];
            myResult["title"] = result["title"]["english"];

            myResult["images"] = [];
            myResult["dimensions"] = [];

            final int numOfPages = result["num_pages"];
            final int mediaID = int.parse(result["media_id"]);

            final imageData = result["images"];

            for (var i = 0; i < numOfPages; i++) {
                final pageIndex = i + 1;
                final image = imageData["pages"][i];

                myResult["images"].add(getImageUrl(mediaID, ImageType.image, mimeString: image["t"], pageNumber: pageIndex).toString());
                myResult["dimensions"].add([image["w"], image["h"]]);
            }

            myResult["preview_url"] = getImageUrl(mediaID, ImageType.cover, mimeString: imageData["cover"]["t"]).toString();
            myResult["tags"] = [];
            myResult["authors"] = [];
            myResult["sources"] = [];
            myResult["characters"] = [];

            for (final tag in result["tags"]) {
                
                if (tag["type"] == "artist" || tag["type"] == "group") {
                    myResult["authors"].add(tag["name"]);
                } else if (tag["type"] == "parody") {
                    myResult["sources"].add(tag["name"]);
                } else if (tag["type"] == "character") {
                    myResult["characters"].add(tag["name"]);
                } else {
                    myResult["tags"].add(tag["name"]);
                }
            }

            (myResult["tags"] as List).sort();

            myResult["poster"] = ((result["scanlator"] as String).isEmpty) ? null : result["scanlator"];

            return myResult;
        } catch(e, stackTrace) {
            Nokulog.e("Failed to fetch post with ID $postID.\n${defaultHeaders["Cookie"]}", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (limit <= 0) limit = 100;
        
        if (postID == null) {
            try {
                final Response<String> response = await _client.get(_randomUrl);
                Nokulog.d(response.redirects.map((e) => e.toString()));
            } catch(e, stackTrace) {
                Nokulog.e("Failed to fetch random post.", error: e, stackTrace: stackTrace);
                return [];
            }
        }

        final List<Map<String, dynamic>> rawComments = [];

        if (postID == null) return rawComments;
        
        try {
            final List<dynamic> comments = await _makeRequest("${_url}gallery/$postID/comments");
            
            for (final comment in comments) {
                rawComments.add({
                    "id": comment["id"],
                    "post_id": postID,
                    "creator_id": comment["poster"]["id"],
                    "creator": comment["poster"]["username"],
                    "creator_avatar": "$_avatarUrl${comment['poster']['avatar_url']}",
                    "body": comment["body"],
                    "created_at": DateTime.fromMillisecondsSinceEpoch(comment["post_date"] * 1000)
                });
            }

            return rawComments;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch comments for post ID $postID.\n${defaultHeaders["Cookie"]}", error: e, stackTrace: stackTrace);
            return rawComments;
        }
    }

    Future<Map<String, dynamic>?> getComment(int commentID, int postID) async {
        if (commentID <= 0 || commentID <= 0) {
            return null;
        }

        final rawComments = await searchComments(postID: postID);

        try {
            return rawComments.firstWhere((element) => element["id"] == commentID);
        } on StateError catch (e, stackTrace) {
            Nokulog.e("No comment with ID $commentID for post $postID exists.", error: e, stackTrace: stackTrace);
            return null;
        } catch(e, stackTrace) {
            Nokulog.e("Unexpected exception when fetching comment.\n${defaultHeaders["Cookie"]}", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> getNotes(int postID) async {
        return [];
    }

    Uri getImageUrl(int mediaID, ImageType type, {String? mimeString, int pageNumber = 1}) {
        String fileString = (mimeString == null) ? "j" : mimeString;

        switch (fileString) {
            case "p":
            case "png":
                fileString = "png";
                break;

            case "g":
            case "gif":
                fileString = "gif";
                break;

            case "w":
            case "webp":
                fileString = "webp";

            case "j":
            default:
                fileString = "jpg";
        }

        switch (type) {
            case ImageType.cover:
                return Uri.parse("$_tinyImageUrl$mediaID/cover.$fileString");

            case ImageType.thumbnail:
                return Uri.parse("$_tinyImageUrl$mediaID/thumb.$fileString");

            case ImageType.image:
                return Uri.parse("$_imageUrl$mediaID/$pageNumber.$fileString");
        }
    }

    Future<dynamic> _makeRequest(String url, {Map<String, String>? params}) async {
        final String paramString = (params != null) ? mapToPairedString(params) : "";
        final Uri requestURL = Uri.parse("$url?$paramString");

        final Response<String> response = await _client.get(requestURL.toString());

        if (response.data == null) {
            throw DioException(
                stackTrace: StackTrace.current,
                type: DioExceptionType.badResponse,
                requestOptions: response.requestOptions,
                response: response,
                message: "Response data was null"
            );
        }

        //Nokulog.d(response.headers.map);

        final decoded = jsonDecode(response.data!);

        if (decoded is String?) {
            Nokulog.d(decoded);
        }

        return decoded;
    }
}