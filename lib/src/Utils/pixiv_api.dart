import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:nokufind/src/Utils/pixiv_utils.dart';

const String referer = "https://app-api.pixiv.net/";

enum Filter { for_ios, empty }
enum Type { illust, manga, empty }
enum Restrict { public, private, empty }
enum ContentType { illust, manga, empty }
enum Mode {
  day, week, month, day_male, day_female, week_original, week_rookie, day_manga,
  day_r18, day_male_r18, day_female_r18, week_r18, week_r18g, empty
}
enum SearchTarget { partial_match_for_tags, exact_match_for_tags, title_and_caption, keyword, empty }
enum Sort { date_desc, date_asc, popular_desc, empty }
enum SearchDuration { within_last_day, within_last_week, within_last_month, empty, none }
enum Bool { trueValue, falseValue }

class BasePixivAPI {
    static String clientID = "MOBrBDS8blbauoSck0ZfDbtuzpyT";
    static String clientSecret = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj";
    static String hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c";

    int userID = 0;
    String? accessToken;
    String? refreshToken;
    CaseInsensitiveMap<String> additionalHeaders = CaseInsensitiveMap<String>();
    Map<String, dynamic> requestsKwargs = {};
    
    String hosts = "https://app-api.pixiv.net";
    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));

    BasePixivAPI({Map<String, dynamic>? requestsKwargs}) {
        additionalHeaders = CaseInsensitiveMap<String>(requestsKwargs?['headers']?.cast<String, String>());
        this.requestsKwargs = requestsKwargs ?? {};
    }

    void setAdditionalHeaders(Map<String, String> headers) {
        additionalHeaders = CaseInsensitiveMap(headers);
    }

    void setAcceptLanguage(String language) {
        additionalHeaders["Accept-Language"] = language;
    }

    void requireAuthentication() {
        if (accessToken == null) {
            throw PixivError("Authentication required! Call setAuth() first!");
        }
    }

    Future<Response<String>> requestsCall(String method, String url, {Map<String, String>? headers, Map<String, dynamic>? params, Map<String, dynamic>? data, bool stream = false}) async {
        final mergedHeaders = Map<String, String>.from(additionalHeaders);

        if (headers != null) {
            mergedHeaders.addAll(headers);
        }

        try {
            switch (method) {
                case "GET":
                return await _client.get(
                    url, 
                    queryParameters: params,
                    options: Options(headers: mergedHeaders, validateStatus: (status) => (status != null && status < 403),)
                );

                case "POST":
                return await _client.post(
                    url,
                    data: (data != null) ? FormData.fromMap(data) : data,
                    options: Options(headers: mergedHeaders, validateStatus: (status) => (status != null && status < 403),)
                );

                case "DELETE":
                return await _client.delete(
                    url,
                    data: (data != null) ? FormData.fromMap(data) : data,
                    options: Options(headers: mergedHeaders)
                );

                default:
                throw PixivError("Unknown method: $method");
            }
        } catch (e) {
            throw PixivError("Requests $method $url error: $e");
        }
    }

    void setAuth(String accessToken, {String? refreshToken}) {
        this.accessToken = accessToken;
        this.refreshToken = refreshToken;
    }

    void setClient(String clientID, String clientSecret) {
        BasePixivAPI.clientID = clientID;
        BasePixivAPI.clientSecret = clientSecret;
    }

    Future<Map<String, dynamic>> auth({String? refreshToken, Map<String, String>? headers}) async {
        final localTime = DateTime.now().toUtc().toIso8601String();
        final otherHeaders = CaseInsensitiveMap<String>(headers);

        otherHeaders["x-client-time"] = localTime;
        otherHeaders["x-client-hash"] = md5.convert(utf8.encode(localTime + hashSecret)).toString();
    
        if (!otherHeaders.containsKey("user-agent")) {
            otherHeaders["app-os"] = "ios";
            otherHeaders["app-os-version"] = "14.6";
            otherHeaders["user-agent"] = "PixivIOSApp/7.13.3 (iOS 14.6; iPhone13,2)";
        }

        final authHosts = "https://oauth.secure.pixiv.net";
        final url = "$authHosts/auth/token";
        final data = {
            "get_secure_url": 1,
            "client_id": clientID,
            "client_secret": clientSecret
        };

        if (refreshToken != null || this.refreshToken != null) {
            data["grant_type"] = "refresh_token";
            data["refresh_token"] = refreshToken ?? this.refreshToken!;
        } else {
            throw PixivError("[ERROR] auth() but no refresh_token is set.");
        }

        Map<String, dynamic> token = {};

        Response<String> response = await requestsCall("POST", url, headers: otherHeaders, data: data);

        try {
            token = jsonDecode(response.data!);
            userID = int.parse(token["response"]["user"]["id"]);
            accessToken = token["response"]["access_token"];
            this.refreshToken = token["response"]["refresh_token"];
        } catch (e) {
            throw PixivError("Get access_token error! $e\nResponse: ${response.data}", header: response.requestOptions.headers, body: response.data);
        }

        return token;
    }
}

class AppPixivAPI extends BasePixivAPI{
    AppPixivAPI({super.requestsKwargs});

    void setApiProxy([String proxyHosts = "http://app-api.pixivlite.com"]) {
        hosts = proxyHosts;
    }

    Future<Response<String>> noAuthRequestsCall(
        String method,
        String url,
        {Map<String, String>? headers,
        Map<String, dynamic>? params,
        Map<String, dynamic>? data,
        bool requestAuth = true}
    ) async {
        var headers_ = CaseInsensitiveMap<String>(headers ?? {});
        if (hosts != "https://app-api.pixiv.net") {
            headers_["host"] = "app-api.pixiv.net";
        }

        if (!headers_.containsKey("user-agent")) {
            headers_["app-os"] = "ios";
            headers_["app-os-version"] = "14.6";
            headers_["user-agent"] = "PixivIOSApp/7.13.3 (iOS 14.6; iPhone13,2)";
        }

        if (!requestAuth) {
            return await requestsCall(method, url, headers: Map<String, String>.from(headers_), params: params, data: data);
        }

        requireAuthentication();
        headers_["Authorization"] = "Bearer $accessToken";
        return await requestsCall(method, url, headers: Map<String, String>.from(headers_), params: params, data: data);
    }

    Map<String, dynamic> parseResult(Response<String> response) {
        try {
            return jsonDecode(response.data!);
        } catch(e) {
            throw PixivError("parseResult() error: $e", header: response.requestOptions.headers, body: response.data);
        }
    }

    static String formatBool(bool value) => (value) ? "true" : "false";
    static String formatDate(DateTime date) => "${date.year}-${date.month}-${date.day}";

    static Map<String, dynamic>? parseQs(String? nextURL) {
        if (nextURL == null) {
            return null;
        }

        final resultQs = <String, dynamic>{};
        final query = Uri.parse(nextURL).queryParameters;

        query.forEach((key, value) {
            if (key.contains("[") && key.endsWith("]")) {
                resultQs[key.split('[')[0]] = value;
                return;
            }

            resultQs[key] = value;
        });

        return resultQs;
    }

    Future<Map<String, dynamic>> userDetail(dynamic userID, {Filter filter = Filter.for_ios, bool requestAuth = true}) async {
        final url = "$hosts/v1/user/detail";
        final params = {
            "user_id": userID, 
            "filter": filter.name,
        };

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userIllusts(dynamic userID, {Type type = Type.illust, Filter filter = Filter.for_ios, dynamic offset, bool requestAuth = true}) async {
        final url = "$hosts/v1/user/illusts";
        final params = {
            "user_id": userID,
            "filter": filter.name
        };

        if (type != Type.empty) {
            params["type"] = type.name;
        }

        if (offset != null) {
            params["offset"] = offset;
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userBookmarksIllust(
        dynamic userID, {
            Restrict restrict = Restrict.public, 
            Filter filter = Filter.for_ios, 
            dynamic maxBookmarkID, 
            String? tag, 
            bool requestAuth = true
        }
    ) async {
        final url = "$hosts/v1/user/bookmarks/illust";
        final params = {
            "user_id": userID,
            "restrict": restrict.name,
            "filter": filter.name
        };

        if (maxBookmarkID != null) {
            params["max_bookmark_id"] = maxBookmarkID;
        }

        if (tag != null) {
            params["tag"] = tag;
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userRelated(dynamic seedUserID, {Filter filter = Filter.for_ios, dynamic offset, bool requestAuth = true}) async {
        final url = "$hosts/v1/user/related";
        final params = {
            "filter": filter.name,
            "offset": offset ?? 0,
            "seed_user_id": seedUserID
        };

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userRecommended({Filter filter = Filter.for_ios, dynamic offset, bool requestAuth = true}) async {
        final url = "$hosts/v1/user/recommended";
        final params = {
            "filter": filter.name
        };

        if (offset != null) {
            params["offset"] = offset;
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustFollow({Restrict restrict = Restrict.public, dynamic offset, bool requestAuth = true}) async {
        final url = "$hosts/v2/illust/follow";
        final params = {
            "restrict": restrict.name
        };

        if (offset != null) {
            params["offset"] = offset;
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustDetail(dynamic illustID, {bool requestAuth = true}) async {
        final url = "$hosts/v1/illust/detail";
        final params = {
            "illust_id": illustID
        };

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustComments(dynamic illustID, {dynamic offset, bool? includeTotalComments, bool requestAuth = true}) async {
        final url = "$hosts/v3/illust/comments";
        final params = {
            "illust_id": illustID,
        };

        if (offset != null) {
            params["offset"] = offset;
        }

        if (includeTotalComments != null) {
            params["include_total_comments"] = formatBool(includeTotalComments);
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustRelated(dynamic illustID, {Filter filter = Filter.for_ios, dynamic seedIllustIDs, dynamic offset, dynamic viewed, bool requestAuth = true}) async {
        final url = "";
        final params = {
            "illust_id": illustID,
            "filter": filter.name,
            "offset": offset
        };

        if (seedIllustIDs != null) {
            params["seed_illust_ids[]"] = (seedIllustIDs is List) ? seedIllustIDs : [seedIllustIDs];
        }

        if (viewed != null) {
            params["viewed[]"] = (viewed is List) ? viewed : [viewed];
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustRecommended({
        ContentType contentType = ContentType.illust,
        bool includeRankingLabel = true,
        Filter filter = Filter.for_ios,
        int? maxBookmarkIDForRecommend,
        int? minBookmarkIDForRecentIllust,
        int? offset,
        bool? includeRankingIllusts,
        List<int>? bookmarkIllustIDs,
        List<int>? includePrivacyPolicy,
        List<String>? viewed,
        bool requestAuth = true 
    }) async {
        final url = (requestAuth) ? "$hosts/v1/illust/recommended" : "$hosts/v1/illust/recommended-nologin";
        final params = <String, dynamic>{
            "content_type": contentType.name,
            "include_ranking_label": formatBool(includeRankingLabel),
            "filter": filter.name
        };
        
        if (maxBookmarkIDForRecommend != null) {
            params["max_bookmark_id_for_recommend"] = maxBookmarkIDForRecommend;
        }

        if (minBookmarkIDForRecentIllust != null) {
            params["min_bookmark_id_for_recent_illust"] = minBookmarkIDForRecentIllust;
        }

        if (offset != null) {
            params["offset"] = offset;
        }

        if (includeRankingIllusts != null) {
            params["include_ranking_illusts"] = formatBool(includeRankingIllusts);
        }

        if (viewed != null) {
            params["viewed[]"] = viewed;
        }

        if (!requestAuth && bookmarkIllustIDs != null) {
            params["bookmark_illust_ids"] = bookmarkIllustIDs.join(",");
        }

        if (includePrivacyPolicy != null) {
            params["include_privacy_policy"] = includePrivacyPolicy;
        }

        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> illustRanking({
        Mode mode = Mode.day,
        Filter filter = Filter.for_ios,
        DateTime? date,
        int? offset,
        bool requestAuth = true
    }) async {
        final url = "$hosts/v1/illust/ranking";
        final params = <String, dynamic>{
            "mode": mode.name,
            "filter": filter.name
        };

        if (date != null) {
            params["date"] = formatDate(date);
        }

        if (offset != null) {
            params["offset"] = offset;
        }
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> trendingTagsIllust({
        Filter filter = Filter.for_ios,
        bool requestAuth = true
    }) async {
        final url = "$hosts/v1/trending-tags/illust";
        final params = <String, dynamic>{
            "filter": filter.name
        };
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> searchIllust(
        String word, {
            SearchTarget searchTarget = SearchTarget.partial_match_for_tags,
            Sort sort = Sort.date_desc,
            SearchDuration duration = SearchDuration.none,
            DateTime? startDate,
            DateTime? endDate,
            Filter filter = Filter.for_ios,
            int? offset,
            bool requestAuth = true
    }) async {
        final url = "$hosts/v1/search/illust";
        final params = <String, dynamic>{
            "word": word,
            "search_target": searchTarget.name,
            "sort": sort.name,
            "filter": filter.name
        };

        if (startDate != null) params["start_date"] = formatDate(startDate);
        if (endDate != null) params["end_date"] = formatDate(endDate);
        if (offset != null) params["offset"] = offset;

        if (duration != SearchDuration.none) params["duration"] = duration.name;
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> searchUser(
        String word, {
            Sort sort = Sort.date_desc,
            SearchDuration duration = SearchDuration.none,
            Filter filter = Filter.for_ios,
            int? offset,
            bool requestAuth = true
    }) async {
        final url = "$hosts/v1/search/user";
        final params = <String, dynamic>{
            "word": word,
            "sort": sort.name,
            "filter": filter.name
        };

        if (duration != SearchDuration.none) params["duration"] = duration.name;
        if (offset != null) params["offset"] = offset;
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userMyPixiv(
        int userID, {
            int? offset,
            bool requestAuth = true
    }) async {
        final url = "$hosts/v1/user/mypixiv";
        final params = <String, dynamic>{
            "user_id": userID,
        };

        if (offset != null) params["offset"] = offset;
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> userList(
        int userID, {
            Filter filter = Filter.for_ios,
            int? offset,
            bool requestAuth = true
    }) async {
        final url = "$hosts/v2/user/list";
        final params = <String, dynamic>{
            "user_id": userID,
            "filter": filter.name
        };

        if (offset != null) params["offset"] = offset;
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }

    Future<Map<String, dynamic>> template({bool requestAuth = true}) async {
        final url = "$hosts/v1";
        final params = <String, dynamic>{
            "": ""
        };
        
        final response = await noAuthRequestsCall("GET", url, params: params, requestAuth: requestAuth);
        return parseResult(response);
    }
}

