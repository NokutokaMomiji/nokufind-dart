import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:html/dom.dart";
import "package:html/parser.dart";
import "package:intl/intl.dart";
import "package:xml/xml.dart";

import "../Utils/utils.dart";

class Rule34API {
    static const String _url = "https://api.rule34.xxx/";
    static const String _siteUrl = "https://rule34.xxx/";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: Duration(seconds: 15)));
    final _dateFormat = DateFormat("yyyy-MM-dd HH:mm:ss");

    Rule34API() {
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 1000, int page = 0}) async {
        if (page < 0) page = 0;
        if (limit <= 0) limit = 1000;
        
        Map<String, String> params = {
            "page": "dapi",
            "s": "post",
            "q": "index",
            "tags": tags,
            "limit": limit.toString(),
            "pid": page.toString(),
            "json": "1"
        };

        try {
            List<dynamic> results = await _makeRequest("index.php", params: params) as List<dynamic>;
            
            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } catch (e) {
            Nokulog.logger.e(e);
            return <Map<String, dynamic>>[];
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        Map<String, String> params = {
            "page": "dapi",
            "s": "post",
            "q": "index",
            "id": postID.toString(),
            "json": "1"
        };

        try {
            List<dynamic> results = await _makeRequest("index.php", params: params) as List<dynamic>;
            
            for (int i = 0; i < results.length;) {
                results[i] = Map<String, dynamic>.from(results[i]);
                return results[i];
            }

            return null;
        } on DioException {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;
        
        Map<String, String> params = {
            "limit": limit.toString(),
            "pid": page.toString()
        };

        params["page"] = "dapi";
        params["s"] = "comment";
        params["q"] = "index";

        List<Map<String, dynamic>> rawComments = [];

        if (postID != null) {
            params["post_id"] = postID.toString();
        }

        String paramString = mapToPairedString(params);
        Uri requestURL = Uri.parse("${_url}index.php?$paramString");
        
        Response<String> content = await _client.get(requestURL.toString());
    
        XmlDocument document = XmlDocument.parse(content.data!);

        for (var child in document.rootElement.children) {
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

        var rawComments = await searchComments(postID: postID);

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

        Map<String, String> cookies = {
            "resize-notification": "1",
            "resize-original": "1"
        };

        Map<String, String> params = {
            "page": "post",
            "s": "view",
            "id": postID.toString()
        };

        List<Map<String, dynamic>> rawNotes = [];

        String paramString = mapToPairedString(params);
        Uri requestURL = Uri.parse("${_siteUrl}index.php?$paramString");
        Uri otherURL = Uri.parse("${_siteUrl}index.php?page=history&type=page_notes&id=$postID");

        _client.options.headers["cookies"] = mapToPairedString(cookies, separator: ';');        
        
        try {
            _client.options.headers["User-Agent"] = userAgent;
            Response<String> content = await _client.get(requestURL.toString());
            Response<String> otherData = await _client.get(otherURL.toString());
            _client.options.headers.remove("User-Agent");

            Document document = parse(content.data!);
            Document otherDoc = parse(otherData.data!);

            Element? noteContainer = document.getElementById("note-container");

            if (noteContainer == null) return [];
            
            for (var i = 0; i < noteContainer.children.length; i += 2) {
                Element noteBox = noteContainer.children[i];
                //Element noteBody = noteContainer.children[i + 1];

                var splitStyle = pairedStringToMap(noteBox.attributes["style"] as String, separator: "; ", unifier: ": ");

                Map<String, dynamic> currentNote = {
                    "x": int.parse(splitStyle["left"]?.replaceAll("px", "") as String),
                    "y": int.parse(splitStyle["top"]?.replaceAll("px", "") as String),
                    "width": int.parse(splitStyle["width"]?.replaceAll("px", "") as String),
                    "height": int.parse(splitStyle["height"]?.replaceAll("px", "") as String),
                    "post_id": postID
                };
                
                rawNotes.add(currentNote);
            }

            var antigraph = "¶";
            Element tcontent = otherDoc.querySelector("tbody") as Element;
            for (var note in rawNotes.indexed) {        
                try {
                    int index = (note.$1 + 1).clamp(tcontent.children.length - 1, tcontent.children.length - 1);
                    List<Element> tableData = tcontent.children[index].children;
                    note.$2["id"] = int.parse(tableData[2].children[0].text.trim());
                    note.$2["body"] = tableData[3].innerHtml.trim().replaceAll(antigraph, "\n");
                    note.$2["created_at"] = _dateFormat.parse(tableData[5].text);
                } catch(e) {
                    Nokulog.logger.e(e);
                    continue;
                }
                
            }
        } catch (e) {
            Nokulog.logger.e(requestURL);
            Nokulog.logger.e(otherURL);
            Nokulog.logger.e(e);
        } 

        return rawNotes;
    }

    Future<dynamic> _makeRequest(String file, {Map<String, String>? params}) async {
        String paramString = (params != null) ? mapToPairedString(params) : "";
        Uri requestURL = Uri.parse("$_url$file?$paramString");

        Nokulog.logger.d(requestURL);
        
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