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
    static const String _imageUrl = "https://i.nhentai.net/galleries/";
    static const String _avatarUrl = "https://i5.nhentai.net/";
    static const String _tinyImageUrl = "https://t.nhentai.net/galleries/";
    static const String _randomUrl = "https://nhentai.net/random/";
    static const String _userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 OPR/109.0.0.0";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: Duration(seconds: 15)));
    //final _dateFormat = DateFormat("yyyy-MM-dd HH:mm:ss");
    
    final String _cfClearance;

    Map<String, String> defaultHeaders = {};

    NHentaiAPI(this._cfClearance) {
        defaultHeaders["User-Agent"] = _userAgent;
        defaultHeaders["Cookie"] = "cf_clearance=$_cfClearance;";
        _client.options.headers = defaultHeaders;
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 25, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 25;
        
        Map<String, String> params = {
            "page": page.toString(),
        };

        if (tags.isNotEmpty) {
            params["q"] = tags;//.replaceAll(" ", "+");
        }

        int innerPage = page;
        List<Map<String, dynamic>> rawPosts = [];
        String requestPart = (tags.isEmpty) ? _siteUrl : "${_siteUrl}search/";

        try {
            while (rawPosts.length < limit) {
                params["page"] = innerPage.toString();

                String paramString = mapToPairedString(params);
                Uri url = Uri.parse("$requestPart?$paramString");

                Nokulog.logger.d(url);
                
                Response<String> response = await _client.get(url.toString());

                Document document = Document.html(response.data!);

                Element? searchResultsContainer = document.querySelector("div .container");

                if (searchResultsContainer == null) {
                    Nokulog.logger.e("No search results container.");
                    return rawPosts;
                }
                
                List<Element> searchResults = document.querySelectorAll("div .gallery");

                if (searchResults.isEmpty) {
                    Nokulog.logger.e("No search results.");
                    return rawPosts;
                }
                List<int> postIDs = [];

                Nokulog.logger.d("Found ${searchResults.length} results.");

                for (var searchResult in searchResults) {
                    Document results = Document.html(searchResult.outerHtml);
                    var tagResults = results.querySelector("a.cover");
                    if (tagResults == null) {
                        continue;
                    }
                
                    Nokulog.logger.d(tagResults.outerHtml);
                    Nokulog.logger.d(tagResults.attributes["href"]);
                    String? tempID = tagResults.attributes["href"]?.split("/")[2];
                
                    if (tempID == null) {
                        continue;
                    }

                    postIDs.add(int.parse(tempID));
                }

                Executor executor = Executor(concurrency: 15, rate: Rate.perSecond(5));

                for (int postID in postIDs) {
                    executor.scheduleTask(() async {
                        var post = await getPost(postID);
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
        } catch (e) {
            Nokulog.logger.d(e);
            return rawPosts;
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        try {
            Nokulog.logger.d("Getting post with id $postID");
            Map<String, dynamic> result = await _makeRequest("${_url}gallery/$postID") as Map<String, dynamic>;

            if (result.containsKey("error")) {
                Nokulog.logger.e("NHentai result: $result");
                return null;
            }

            Map<String, dynamic> myResult = {};

            myResult["id"] = result["id"];
            myResult["title"] = result["title"]["english"];

            myResult["images"] = [];
            myResult["dimensions"] = [];

            int numOfPages = result["num_pages"];
            int mediaID = int.parse(result["media_id"]);

            var imageData = result["images"];

            for (var i = 0; i < numOfPages; i++) {
                var pageIndex = i + 1;
                var image = imageData["pages"][i];

                myResult["images"].add(getImageUrl(mediaID, ImageType.image, mimeString: image["t"], pageNumber: pageIndex).toString());
                myResult["dimensions"].add([image["w"], image["h"]]);
            }

            myResult["preview_url"] = getImageUrl(mediaID, ImageType.cover, mimeString: imageData["cover"]["t"]).toString();
            myResult["tags"] = [];
            myResult["authors"] = [];

            for (var tag in result["tags"]) {
                myResult["tags"].add(tag["name"]);
                if (tag["type"] == "artist" || tag["type"] == "group") {
                    myResult["authors"].add(tag["name"]);
                }
            }

            (myResult["tags"] as List).sort();

            myResult["poster"] = ((result["scanlator"] as String).isEmpty) ? null : result["scanlator"];

            return myResult;
        } on DioException {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (limit <= 0) limit = 100;
        
        if (postID == null) {
            try {
                Response<String> response = await _client.get(Uri.parse(_randomUrl).toString());
                Nokulog.logger.d("headers:");
                Nokulog.logger.d(response.headers);
            } on DioException {
                return [];
            }
        }

        List<Map<String, dynamic>> rawComments = [];

        if (postID == null) return rawComments;
        
        try {
            List<dynamic> comments = await _makeRequest("${_url}gallery/$postID/comments");

            for (var comment in comments) {
                rawComments.add({
                    "id": comment["id"],
                    "post_id": postID,
                    "creator_id": comment["poster"]["id"],
                    "creator": comment["poster"]["username"],
                    "creator_avatar": "$_avatarUrl${comment['poster']['avatar_url']}",
                    "body": comment["body"],
                    "created_at": DateTime.fromMillisecondsSinceEpoch(comment["post_date"])
                });
            }

            return rawComments;
        } catch (e) {
            return rawComments;
        }
    }

    Future<Map<String, dynamic>?> getComment(int commentID, int postID) async {
        if (commentID <= 0 || commentID <= 0) {
            return null;
        }

        var rawComments = await searchComments(postID: postID);

        try {
            return rawComments.firstWhere((element) => element["id"] == commentID);
        } on StateError {
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
                fileString = "png";
                break;

            case "g":
                fileString = "gif";
                break;

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
            default:
                return Uri.parse("$_imageUrl$mediaID/$pageNumber.$fileString");
        }
    }

    Future<dynamic> _makeRequest(String url, {Map<String, String>? params}) async {
        String paramString = (params != null) ? mapToPairedString(params) : "";
        Uri requestURL = Uri.parse("$url?$paramString");

        Response<String> response = await _client.get(requestURL.toString());

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