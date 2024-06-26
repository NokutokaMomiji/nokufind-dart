import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:html/dom.dart";
import "package:intl/intl.dart";
import "package:xml/xml.dart";

import "../Utils/utils.dart";

class GelbooruAPI {
    static const String _url = "https://gelbooru.com/";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    final _dateFormat = DateFormat("yyyy-MM-dd HH:mm:ss");
    final _noteDateFormat = DateFormat("EEE MMM d HH:mm:ss -yyyy yyyy");
    final _profileExpr = RegExp(r"(?<=url\(')(.*?)(?='\))");
    final _commentDateExpr = RegExp(r"(?<=commented at )(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})");
    final _commentIDExpr = RegExp(r"(?<=#)\d+");
    final _commentBodyExpr = RegExp(r"(?<=<br><br>)(.*?)(?=<br><br>)");

    GelbooruAPI() {
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 100, int page = 0}) async {
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
            var contentMap = await _makeRequest("index.php", params: params) as Map<String, dynamic>;
            
            if (!contentMap.containsKey("post")) {
                Nokulog.logger.d("Error: Didn't find key with name post for index.php?${mapToPairedString(params)}.");
                return [];
            }
            
            List<dynamic> results = contentMap["post"];
            
            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } on DioException {
            return List<Map<String, dynamic>>.empty(growable: true);
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
            var response = await _makeRequest("index.php", params: params);
            Map<String, dynamic> data = response as Map<String, dynamic>;

            if (!data.containsKey("post")) return null;

            return data["post"].first;
        } on DioException {
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;
        
        Map<String, String> params = {
            "limit": limit.toString(),
            "pid": ((page - 1) * 10).toString()
        };

        // page=comment&s=list
        params["page"] = "comment";
        params["s"] = "list";
        params["q"] = "index";

        List<Map<String, dynamic>> rawComments = [];

        if (postID != null) {
            params["page"] = "post";
            params["s"] = "view";
            params["q"] = "index";
            params["id"] = postID.toString();
        }

        String paramString = mapToPairedString(params);
        Uri requestURL = Uri.parse("${_url}index.php?$paramString");
        
        Response<String> content = await _client.get(requestURL.toString());
    
        Document document = Document.html(content.data!);

        var comments = (postID == null) ? document.getElementsByClassName("commentHeader") : document.getElementsByClassName("commentBody");
        var otherData = document.getElementsByClassName("commentThumbnail");
        int index = 0;

        for (var comment in comments) {
            Map<String, dynamic> commentData = {};
            var subdocument = Document.html(comment.innerHtml);

            if (postID == null) {
                var commentThumbnail = otherData[index];
                var commentPostLink = commentThumbnail.children.first.attributes["href"] as String;
                commentData["post_id"] = int.parse(commentPostLink.split("=").last);
            } else {
                commentData["post_id"] = postID;
            }

            var commentAvatar = (postID == null) ? subdocument.getElementsByClassName("profileAvatar").first.outerHtml : document.getElementsByClassName("commentAvatar")[index].children.first.outerHtml;
            var commentBody = (postID == null) ? subdocument.getElementsByClassName("commentBody").first : document.getElementsByClassName("commentBody")[index];

            var profileMatch = _profileExpr.firstMatch(commentAvatar);
            commentData["creator_avatar"] = (profileMatch != null) ? "$_url${profileMatch[0]}" : null;

            var profileLink = commentBody.children.first;

            commentData["creator_id"] = int.parse((profileLink.attributes["href"] as String).split("=").last);
            commentData["creator"] = profileLink.children.first.innerHtml.trim();

            var commentContent = commentBody.innerHtml.split("\n")[1].trim();

            commentData["id"] = int.parse(_commentIDExpr.firstMatch(commentContent)?[0] as String);
            commentData["created_at"] = _dateFormat.parse(_commentDateExpr.firstMatch(commentContent)?[0] as String);
            commentData["body"] = _commentBodyExpr.firstMatch(commentContent)?[0] as String;

            rawComments.add(commentData);
            index++;
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

        List<Map<String, dynamic>> rawNotes = [];

        Map<String, String> params = {
            "page": "dapi",
            "s": "note",
            "q": "index",
            "post_id": postID.toString()
        };

        String paramString = mapToPairedString(params);
        Uri requestURL = Uri.parse("${_url}index.php?$paramString");
        
        Response<String> content = await _client.get(requestURL.toString());
    
        XmlDocument document = XmlDocument.parse(content.data!);

        for (var note in document.rootElement.children) {
            rawNotes.add({
                "id": int.parse(note.getAttribute("id") as String),
                "created_at": _noteDateFormat.parse(note.getAttribute("created_at") as String),
                "x": int.parse(note.getAttribute("x") as String),
                "y": int.parse(note.getAttribute("y") as String),
                "width": int.parse(note.getAttribute("width") as String),
                "height": int.parse(note.getAttribute("height") as String),
                "body": note.getAttribute("body") as String,
                "post_id": postID
            });
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