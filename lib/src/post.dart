import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:async/async.dart';
import 'package:dio/dio.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:executor/executor.dart';
import 'package:nokufind/src/Utils/streamed_file.dart';
import 'Utils/utils.dart';

import "package:html_unescape/html_unescape_small.dart";
final temp = HtmlUnescape();

/// Enum that represents the rating of a post.
enum Rating { general, sensitive, questionable, explicit, unknown }

Future<void> generateMD5(Post post) async {
    
}

class Tag {
    final String original;
    final String translated;

    Tag(this.original, {this.translated = ""});

    factory Tag.fromMap(Map<String, dynamic> data) {
        return Tag(temp.convert(data["original"].toString()), translated: temp.convert(data["translated"].toString()));
    }

    bool contains(Pattern other, [int startIndex = 0]) {
        return original.contains(other, startIndex) || translated.contains(other, startIndex);
    }

    bool startsWith(Pattern pattern, [int index = 0]) {
        return original.startsWith(pattern, index) || translated.startsWith(pattern, index);
    }

    Tag toLowerCase() {
        if (original.toLowerCase() == original && translated.toLowerCase() == translated) {
            return this;
        }

        return Tag(original.toLowerCase(), translated: translated.toLowerCase());
    }

    Map<String, dynamic> toMap() {
        return {
            "original": original,
            "translated": translated
        };
    }

    @override
    bool operator ==(Object other) {
        if (identical(this, other)) return true;
        if (other is! Tag) return false;
        return other.original == original && other.translated == translated;
    }

    @override
    int get hashCode => original.hashCode ^ translated.hashCode;

    @override
    String toString() {
        return original;
    }
}

class Post {
    static List<String> ratingGeneral = ["safe", "general", "g"];
    static List<String> ratingSensitive = ["sensitive", "s"];
    static List<String> ratingQuestionable = ["questionable", "q"];
    static List<String> ratingExplicit = ["explicit", "e"];
    static bool generateMissingMD5 = false;
    static Rate? fetchRate;

    static Rating getRating(String? ratingString) {
        if (ratingString == null) return Rating.unknown;

        ratingString = ratingString.toLowerCase();

        if (ratingGeneral.contains(ratingString))       return Rating.general;
        if (ratingSensitive.contains(ratingString))     return Rating.sensitive;
        if (ratingQuestionable.contains(ratingString))  return Rating.questionable;
        if (ratingExplicit.contains(ratingString))      return Rating.explicit;

        return Rating.unknown;
    }

    static Post importPost(String filePath) {
        String fileContent = File(filePath).readAsStringSync();
        Map<String, dynamic> jsonData = jsonDecode(fileContent);

        return importPostFromMap(jsonData);
    }

    static Post importPostFromMap(Map<String, dynamic> jsonData) {
        for (var i = 0; i < jsonData["dimensions"].length; i++) {
            jsonData["dimensions"][i] = List<int>.from(jsonData["dimensions"][i]);
        }
        
        Map<String, String> headers = {};

        if (jsonData.containsKey("headers")) {
            headers = Map<String, String>.from(jsonData["headers"]);
        }

        return Post(
            postID: jsonData["post_id"],
            tags: (jsonData["tags"] as List).map<Tag>((element) {
                if (element is Map) {
                    return Tag.fromMap(Map<String, String>.from(element));
                }

                if (element is String) {
                    return Tag(element);
                }

                throw Exception("Tag data is not valid. Must be String or Map<String, String>.");
            }).toList(),
            sources: List<String>.from(jsonData["sources"]),
            images: List<String>.from(jsonData["images"]),
            authors: List<String>.from(jsonData["authors"]),
            source: jsonData["source"],
            preview: jsonData["preview"],
            md5: List<String>.from(jsonData["md5"]),
            rating: Rating.values[jsonData["rating"]],
            parentID: jsonData["parent_id"],
            dimensions: jsonData["dimensions"],
            poster: jsonData["poster"],
            posterID: jsonData["poster_id"],
            title: jsonData["name"]
        )..setHeaders(headers);
    }

    Map<String, dynamic> postData = {};
    Map<String, String> headers = {};
    Map<String, String> cookies = {};
    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    final Dio _fallbackClient = Dio();
    late List<StreamedFile> data;
    Executor? _executor;
    bool _fetched = false;

    Post? _parent;
    List<Post> _children = [];

    Post({required int postID, 
          required List<Object> tags, 
          required List<String> sources, 
          required List<String> images, 
          required List<String> authors, 
          required String source, 
          required String preview, 
          required List<String>? md5, 
          required dynamic rating, 
          required int? parentID, 
          required List<dynamic> dimensions, 
          required String poster, 
          required int? posterID, 
          required String? title}) {
        
        addSmartRetry(_client);
        addSmartRetry(_fallbackClient);

        postData["post_id"] = postID;
        postData["tags"] = tags.map((element) {
            if (element is String) {
                return Tag(element);
            }

            if (element is Tag) {
                return element;
            }

            throw TypeError();
        }).toList();
        postData["sources"] = sources;
        postData["images"] = images;
        postData["authors"] = authors;
        postData["source"] = source;
        postData["preview"] = preview;
        postData["md5"] = md5 ?? <String>[];
        postData["rating"] = (rating is Rating) ? rating : Post.getRating(rating);
        postData["parent_id"] = parentID;
        postData["dimensions"] = [for (var dimension in dimensions) List<int>.from(dimension)];
        postData["poster"] = poster;
        postData["poster_id"] = posterID;
        postData["name"] = title ?? "Post #$postID";
        postData["filenames"] = List<String>.empty(growable: true);

        postData["images"].forEach((item) {
            postData["filenames"].add(item.split("/").last);
        });

        int numOfFiles = postData["images"].length;
        data = List.unmodifiable([
            for (int i = 0; i < numOfFiles; i++) StreamedFile(
                url: this.images[i], 
                filename: filenames[i], 
                headers: headers, 
                client: _client, 
                fallbackClient: _fallbackClient
            )
        ]);

        if ((postData["md5"] as List).isEmpty && generateMissingMD5) {
            Future.microtask(() => generateMD5(this));
        }
    }

    Future<String> exportPost(String path, {bool withImages = false}) async {
        await Directory(path).create(recursive: true);
    
        String filePath = "$path/$identifier.json";

        await File(filePath).writeAsString(toJsonString());

        if (!withImages) return filePath;

        await downloadAll(path);

        return filePath;
    }

    Future<String?> downloadImage(String path, {int index = 0}) async {
        Directory(path).createSync(recursive: true);
        String filePath = "$path/${filenames[index]}";

        var possibleData = get(data, index, defaultValue: null)?.data;

        if (possibleData != null) {
            await File(filePath).writeAsBytes(possibleData, flush: true);
            return filePath;
        }

        String requestURL = images[index];
        
        Map<String, String> temp = _prepareHeaders();

        _client.options.headers = temp;
        _client.options.responseType = ResponseType.bytes;

        try {
            Response<Uint8List> response = await _client.get(requestURL);
            await File(filePath).writeAsBytes(response.data!, flush: true);
            return filePath;
        } catch (e, stackTrace) {
            Nokulog.w("Failed. Trying fallback client.", error: e, stackTrace: stackTrace);
        }

        try {
            _fallbackClient.options.headers = temp;
            _fallbackClient.options.responseType = ResponseType.bytes;
            Response<Uint8List> response = await _fallbackClient.get(requestURL);
            await File(filePath).writeAsBytes(response.data!, flush: true);
            return filePath;
        } catch (e, stackTrace) {
            Nokulog.e(requestURL, error: e, stackTrace: stackTrace);
            return null;
        }
    }
    
    Future<List<String?>> downloadAll(String path) async {
        Executor executor = Executor(concurrency: 10, rate: fetchRate);
        
        for (int i = 0; i < images.length; i++) {
            executor.scheduleTask(() async {
                return await downloadImage(path, index: i);
            });
        }

        List<String?> values = List<String?>.from(await executor.join(withWaiting: true));
        await executor.close();

        return values;
    }

    void updateHeaders() {
        for (var file in data) {
            file.headers = headers;
        }
    }

    Post setHeaders(Map<String, String> headers) {
        this.headers = headers;
        return this;
    }

    Post setCookies(Map<String, String> cookies) {
        this.cookies = cookies;
        return this;
    }

    String toJsonString() {
        var data = Map<String, dynamic>.from(postData);
        data["headers"] = headers;

        return jsonEncode(data, toEncodable: (obj) {
            if (obj is Rating) return obj.index;
            if (obj is Tag) return obj.toMap();
            return obj;
        });
    }

    Map<String, dynamic> toJson() {
    	try {
            var data = Map<String, dynamic>.from(postData);
            if (data["rating"] is Rating) data["rating"] = (data["rating"] as Rating).index;
            data["tags"] = (data["tags"] as List).map((e) => e.toMap()).toList();
            data["headers"] = headers;
            return data;
        } catch (e, stackTrace) {
            Nokulog.e("Failed to convert post to JSON.", error: e, stackTrace: stackTrace);
            rethrow;
        }
    }

    Future<void> fetchData({bool onlyMainImage = false}) async {
        List<StreamedFile> unfetchedFiles = data.where((file) => file.data != null).toList();
        
        if ((onlyMainImage && data.first.data != null) || (unfetchedFiles.isEmpty)) {
            Nokulog.w("All requested data has been fetched for post. Returning.");
            return;
        }

        if (onlyMainImage) {
            await data.first.awaitData();
            return;
        }

        Executor executor = Executor(concurrency: 10, rate: fetchRate);
        _executor = executor;

        Nokulog.d("$identifier data length: ${data.length}");

        for (var file in unfetchedFiles) {
            try {
                executor.scheduleTask(() async {
                    Nokulog.d("$identifier requesting image \"${file.url}\"...");
                    await file.fetchFile();
                });
            } catch (e, stackTrace) {
                Nokulog.e("Failed to fetch file.", error: e, stackTrace: stackTrace);
                continue;
            }
        }

        await executor.join(withWaiting: true);
        await executor.close();
    }

    Future<void> cancelFetch() async {
        Executor? executor = _executor;

        if (executor == null) return;

        await executor.close();
        _executor = null;
    }

    void clearData([bool keepMainImage = true]) async {
        if (keepMainImage && data.length == 1) return;

        var files = (keepMainImage) ? data.sublist(1) : data;
    
        for (var file in files) {
            file.clear();
        }
    }

    Map<String, String> _prepareHeaders() {
        Map<String, String> temp = Map<String, String>.from(headers);
        if (cookies.isEmpty) return temp;

        temp["Cookie"] = mapToPairedString(cookies, separator: ';');
        return temp;
    }

    Post? setParent(Post? parentPost) {
        _parent = parentPost;
        return parentPost;
    }

    List<Post> setChildren(List<Post> childrenPosts) {
        _children = childrenPosts;
        return _children;
    }

    @override
    String toString() {
        return toJsonString();
    }

    int get postID => postData["post_id"];
    
    List<Tag> get tags => postData["tags"];
    
    List<String> get sources => postData["sources"];
    
    List<String> get images => postData["images"];
    
    String get image => postData["images"][0];
    
    List<String> get authors => postData["authors"];
    
    String get source => postData["source"];
    
    String get preview => postData["preview"];
    
    List<String> get md5 => postData["md5"];
    
    Rating get rating => postData["rating"];
    
    int? get parentID => postData["parent_id"];
    
    List<List<int>> get dimensions => postData["dimensions"];
    
    String get poster => postData["poster"];
    
    int? get posterID => postData["poster_id"];
    
    String get title => postData["name"];
    
    List<String> get filenames => postData["filenames"];
    
    String get identifier => "${source}_$postID";
    
    bool get fetchedData => _fetched;

    Post? get parent => _parent;

    List<Post> get children => _children;

    bool get isVideo => (
        image.toLowerCase().endsWith(".mp4") || 
        image.toLowerCase().endsWith(".webm") || 
        image.toLowerCase().endsWith(".mkv") || 
        image.toLowerCase().endsWith(".mov")
    );

    bool get isZip => (image.toLowerCase().endsWith(".zip"));
}
