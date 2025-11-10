import "dart:convert";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:nokufind/src/API/api_tools.dart";
import "../Utils/utils.dart";

class DanbooruAPI extends BaseAPI{
    static const String _url = "https://danbooru.donmai.us/";

    DanbooruAPI() : super(
        Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)))
    ){
        addSmartRetry(client);

        errors.listen((data) {
            _logAPIError(data);
        });
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags,{int limit = 200, int page = 1}) async {
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 200;
        
        final Map<String, String> params = {
            "tags": tags,
            "limit": limit.toString(),
            "page": page.toString()
        };

        try {
            final request = await _makeRequest("posts.json", params: params);
            
            if (request.isError) return [];

            final results = List.from(request.data);

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
            final request = await _makeRequest("posts/$postID.json");

            if (request.isError) return null;

            return Map<String, dynamic>.from(request.data);
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
            "page": page.toString()
        };
        
        try {
            if (postID != null) {
                params["search[post_id]"] = postID.toString();
            }
            final request = await _makeRequest("comments.json", params: params);

            if (request.isError) return [];

            final results = List<dynamic>.from(request.data);

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
            final request = await _makeRequest("comments/$commentID.json");

            if (request.isError) return null;

            return Map<String, dynamic>.from(request.data);
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
            final request = await _makeRequest("notes.json", params: { "search[post_id]": postID.toString() });
        
            if (request.isError) return [];

            final results = List<dynamic>.from(request.data);

            for (int i = 0; i < results.length; i++) {
                results[i] = Map<String, dynamic>.from(results[i]);
            }

            return List<Map<String, dynamic>>.from(results);
        } catch (e, stackTrace) {
            Nokulog.e("Failed to fetch notes for post $postID.", error: e, stackTrace: stackTrace);
            return [];
        }
    }

    Future<Map<String, dynamic>?> getDescription(int postID) async {
        if (postID <= 0) {
            return null;
        }
        
        try {
            return ((await _makeRequest("posts/$postID/artist_commentary.json")).data ?? {}) as Map<String, dynamic>;
        } catch (e, stackTrace) {
            if (e is DioException) {
                // This means that the commentary simply didn't exist.
                // There's no real reason to log the error, I think, since it's expected.
                if (e.response?.statusCode == 404) {
                    return null;
                }
            }

            Nokulog.e("Failed to fetch description for post ID $postID.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    void _logError(String message, {Object? error, StackTrace? stackTrace}) {
        Nokulog.e("[DanbooruAPI]: $message", error: error, stackTrace: stackTrace);
    }

    void _logAPIError(APIError error) {
        final buffer = StringBuffer();

        buffer.writeln("An error has occurred whilst handling an API request.");
        buffer.writeln("    > [Type]: ${error.type.name}");
        buffer.writeln("    > [Message]: ${error.message}");
        buffer.write  ("    > [URL]: ${error.url}");

        // Yes, the space above is cursed, but this is more visually pleasant.

        _logError(buffer.toString(), error: error.exception, stackTrace: error.stackTrace);
    } 

    Future<APIResult<dynamic>> _makeRequest(String file, {Map<String, String>? params}) async {
        return safeGET(
            "$_url$file", 
            (data) => jsonDecode(data),
            queryParameters: params,
            options: Options(
                headers: {
                    "User-Agent": userAgent
                }
            )
        );

        final String paramString = (params != null) ? mapToPairedString(params) : "";
        final Uri requestURL = Uri.parse("$_url$file?$paramString");
        Nokulog.d(requestURL.toString());
        
        client.options.validateStatus = (status) => true;
        client.options.headers["User-Agent"] = userAgent;
        final Response<String> response = await client.get(requestURL.toString());

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