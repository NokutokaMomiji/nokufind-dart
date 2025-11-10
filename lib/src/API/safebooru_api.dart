import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:html/dom.dart";
import "package:html/parser.dart";
import "package:intl/intl.dart";
import "package:nokufind/src/API/api_tools.dart";
import "package:xml/xml.dart";
import "package:html_unescape/html_unescape_small.dart";

import "../Utils/utils.dart";

class SafebooruApi extends BaseAPI {
    static const String _url = "https://safebooru.org/";
    static const String _siteUrl = "https://safebooru.org/";
    static final HtmlUnescape _unescape = HtmlUnescape();

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    final _dateFormat = DateFormat("yyyy-MM-dd HH:mm:ss");

    SafebooruApi() : super(
        Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)))
    ){
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 1000, int page = 0}) async {
        if (page < 0) page = 0;
        if (limit <= 0) limit = 1000;
        
        final Map<String, String> params = {
            "page": "dapi",
            "s": "post",
            "q": "index",
            "tags": tags,
            "limit": limit.toString(),
            "pid": page.toString(),
            "json": "1"
        };

        try {
            final List<dynamic> results = await _makeRequest("index.php", params: params) as List<dynamic>;
            
            if (results.isEmpty) return const [];

            final Executor executor = Executor(concurrency: 30);

            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);

                executor.scheduleTask(() async {
                    final List<String> tags = (_unescape.convert(results[i]["tags"] as String)).split(" ");
                    final String directory = results[i]["directory"].toString();

                    final String image = results[i]["image"];
                    final String imageFilename = image.substring(0, image.lastIndexOf("."));

                    results[i]["file_url"] = "${_url}images/$directory/$image";
                    results[i]["preview_url"] = "${_url}thumbnails/$directory/thumbnail_$imageFilename.jpg";
                    results[i]["tags"] = tags;
                });
            }

            await executor.join(withWaiting: true);

            return List<Map<String, dynamic>>.from(results);
        } catch (e, stackTrace) {
            Nokulog.e("Failed to search posts matching tags \"$tags\"", error: e, stackTrace: stackTrace);
            return const <Map<String, dynamic>>[];
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        final Map<String, String> params = {
            "page": "dapi",
            "s": "post",
            "q": "index",
            "id": postID.toString(),
            "json": "1"
        };

        try {
            final List<dynamic> results = await _makeRequest("index.php", params: params) as List<dynamic>;
            
            for (final int i = 0; i < results.length;) {
                results[i] = Map<String, dynamic>.from(results[i]);

                final tags = (_unescape.convert(results[i]["tags"] as String)).split(" ");
                final String directory = results[i]["directory"].toString();
                final String image = results[i]["image"];
                final String imageFilename = image.substring(0, image.lastIndexOf("."));

                results[i]["file_url"] = "${_url}images/$directory/$image";
                results[i]["preview_url"] = "${_url}thumbnails/$directory/thumbnail_$imageFilename.jpg";

                results[i]["tags"] = tags;

                return results[i];
            }

            return null;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch post $postID.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;
        
        final Map<String, String> params = {
            "limit": limit.toString(),
            "pid": page.toString()
        };

        params["page"] = "dapi";
        params["s"] = "comment";
        params["q"] = "index";

        final List<Map<String, dynamic>> rawComments = [];

        if (postID != null) {
            params["post_id"] = postID.toString();
        }

        final String paramString = mapToPairedString(params);
        final Uri requestURL = Uri.parse("${_url}index.php?$paramString");
        
        final Response<String> content = await _client.get(requestURL.toString());
    
        final XmlDocument document = XmlDocument.parse(content.data!);

        for (final child in document.rootElement.children) {
            rawComments.add({
                "created_at": DateTime.parse(child.getAttribute("created_at") as String),
                "post_id": int.parse(child.getAttribute("post_id") as String),
                "body": child.getAttribute("body"),
                "creator": child.getAttribute("creator"),
                "id": int.parse(child.getAttribute("id") as String),
                "creator_id": int.parse(child.getAttribute("creator_id") as String)
            });
        }

        return rawComments;
    }

    Future<Map<String, dynamic>?> getComment(int commentID, int postID) async {
        if (commentID <= 0 || commentID <= 0) {
            return null;
        }

        final rawComments = await searchComments(postID: postID);

        try {
            return rawComments.firstWhere((element) => element["id"] == commentID);
        } on StateError {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> getNotes(int postID) async {
        if (postID <= 0) {
            return List.empty();
        }

        final Map<String, String> cookies = {
            "resize-notification": "1",
            "resize-original": "1"
        };

        final Map<String, String> params = {
            "page": "post",
            "s": "view",
            "id": postID.toString()
        };

        final List<Map<String, dynamic>> rawNotes = [];

        final String paramString = mapToPairedString(params);
        final Uri requestURL = Uri.parse("${_siteUrl}index.php?$paramString");
        final Uri otherURL = Uri.parse("${_siteUrl}index.php?page=history&type=page_notes&id=$postID");

        _client.options.headers["cookies"] = mapToPairedString(cookies, separator: ';');        
        
        try {
            _client.options.headers["User-Agent"] = userAgent;
            final Response<String> content = await _client.get(requestURL.toString());
            final Response<String> otherData = await _client.get(otherURL.toString());
            _client.options.headers.remove("User-Agent");

            final Document document = parse(content.data!);
            final Document otherDoc = parse(otherData.data!);

            final Element? noteContainer = document.getElementById("note-container");

            if (noteContainer == null) return [];
            
            for (var i = 0; i < noteContainer.children.length; i += 2) {
                final Element noteBox = noteContainer.children[i];
                //Element noteBody = noteContainer.children[i + 1];

                final splitStyle = pairedStringToMap(noteBox.attributes["style"] as String, separator: "; ", unifier: ": ");

                final Map<String, dynamic> currentNote = {
                    "x": int.parse(splitStyle["left"]?.replaceAll("px", "") as String),
                    "y": int.parse(splitStyle["top"]?.replaceAll("px", "") as String),
                    "width": int.parse(splitStyle["width"]?.replaceAll("px", "") as String),
                    "height": int.parse(splitStyle["height"]?.replaceAll("px", "") as String),
                    "post_id": postID
                };
                
                rawNotes.add(currentNote);
            }

            final antigraph = "¶";
            final Element tcontent = otherDoc.querySelector("tbody") as Element;
            for (final note in rawNotes.indexed) {        
                try {
                    final int index = (note.$1 + 1).clamp(tcontent.children.length - 1, tcontent.children.length - 1);
                    final List<Element> tableData = tcontent.children[index].children;
                    note.$2["id"] = int.parse(tableData[2].children[0].text.trim());
                    note.$2["body"] = tableData[3].innerHtml.trim().replaceAll(antigraph, "\n");
                    note.$2["created_at"] = _dateFormat.parse(tableData[5].text);
                } catch(e) {
                    Nokulog.e(e);
                    continue;
                }
                
            }
        } catch (e) {
            Nokulog.e(requestURL);
            Nokulog.e(otherURL);
            Nokulog.e(e);
        } 

        return rawNotes;
    }

    Future<dynamic> _makeRequest(String file, {Map<String, String>? params}) async {
        final String paramString = (params != null) ? mapToPairedString(params) : "";
        final Uri requestURL = Uri.parse("$_url$file?$paramString");
        
        final Response<String> response = await _client.get(requestURL.toString());
        
        if (response.data == null || response.data?.isEmpty == true) {
            throw DioException(
                stackTrace: StackTrace.current,
                type: DioExceptionType.badResponse,
                requestOptions: response.requestOptions,
                response: response,
                message: "Response data was null"
            );
        }

        return jsonDecode(response.data!);
    }
}