import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:html/parser.dart";
import "package:intl/intl.dart";

import "../Utils/utils.dart";

class YandereAPI {
    static const String _url = "https://yande.re/";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    final _dateFormat = DateFormat("EEE MMM dd HH:mm:ss yyyy");

    YandereAPI() {
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 100, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;
        
        Map<String, String> params = {
            "tags": tags,
            "limit": limit.toString(),
            "page": page.toString()
        };

        try {
            List<dynamic> results = await _makeRequest("post.json", params: params) as List<dynamic>;
            
            for (int i = 0; i < results.length; i++) {
                var map = Map<String, dynamic>.from(results[i]);
                map["rating"] = (map["rating"] == "s") ? "general" : map["rating"];
                results[i] = map;
            }

            return List<Map<String, dynamic>>.from(results);
        } on DioException {
            return List<Map<String, dynamic>>.empty(growable: true);
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        try {
            var result = await searchPosts("id:$postID");
            if (result.isEmpty) {
                return null;
            }
            return result.first;
        } on DioException {
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

        _client.options.headers = params;
        Response<String> response = await _client.get(Uri.parse(url).toString());
        _client.options.headers = null;

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

            Nokulog.d(comment);
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

    Future<dynamic> _makeRequest(String file, {Map<String, String>? params}) async {
        String paramString = (params != null) ? mapToPairedString(params) : "";
        Uri requestURL = Uri.parse("$_url$file?$paramString");
        
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