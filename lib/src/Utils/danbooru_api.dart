import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "../Utils/utils.dart";

class DanbooruAPI {
    static const String _url = "https://danbooru.donmai.us/";
    
    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));

    DanbooruAPI() {
        addSmartRetry(_client);
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 200, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 200;
        
        Map<String, String> params = {
            "tags": tags,
            "limit": limit.toString(),
            "page": page.toString()
        };

        try {
            List<dynamic> results = await _makeRequest("posts.json", params: params) as List<dynamic>;
            
            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } catch (e, stackTrace) {
            Nokulog.e("Failed to find posts matching \"$tags\"", error: e, stackTrace: stackTrace);
            return [];
        }
    }

    Future<Map<String, dynamic>?> getPost(int postID) async {
        try {
            return await _makeRequest("posts/$postID.json") as Map<String, dynamic>;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch post $postID.", error: e, stackTrace: stackTrace);
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
        
        try {
            if (postID != null) {
                params["search[post_id]"] = postID.toString();
            }
            List<dynamic> results = await _makeRequest("comments.json", params: params) as List<dynamic>;

            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
            
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch comments.", error: e, stackTrace: stackTrace);
            return [];
        }
    }

    Future<Map<String, dynamic>?> getComment(int commentID) async {
        if (commentID <= 0) {
            return null;
        }
        
        try {
            return await _makeRequest("comments/$commentID.json") as Map<String, dynamic>;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch comment with ID $commentID.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> getNotes(int postID) async {
        if (postID <= 0) {
            return [];
        }

        try {
            List<dynamic> results = await _makeRequest("notes.json", params: { "search[post_id]": postID.toString() }) as List<dynamic>;
        
            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch notes for post $postID.", error: e, stackTrace: stackTrace);
            return [];
        }
    }

    Future<dynamic> _makeRequest(String file, {Map<String, String>? params}) async {
        String paramString = (params != null) ? mapToPairedString(params) : "";
        Uri requestURL = Uri.parse("$_url$file?$paramString");
        Nokulog.d(requestURL.toString());
        
        _client.options.validateStatus = (status) => true;
        _client.options.headers["User-Agent"] = userAgent;
        Response<String> response = await _client.get(requestURL.toString());

        if (response.data == null) {
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