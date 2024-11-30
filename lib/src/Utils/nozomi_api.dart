import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";

import "../Utils/utils.dart";

String thumbnailFromImageUrl(String imageUrl, String originalFormat) {
    String newDomain = imageUrl.replaceAll("w.nozomi.la", "tn.nozomi.la");
    String ext = imageUrl.split(".").last;
    return newDomain.replaceAll(ext, "$originalFormat.webp");
}

String fullPathFromHash(String hash) {
    if (hash.length < 3) {
        return hash;
    }
    
    // Use RegExp to match the pattern
    RegExp regExp = RegExp(r'^.*(..)(.)$');
    RegExpMatch? match = regExp.firstMatch(hash);

    if (match != null) {
        String part2 = match.group(2)!;
        String part1 = match.group(1)!;
        return '$part2/$part1/$hash';
    }

    // If no match is found, return the original hash (this should not happen with the given pattern)
    return hash;
}

class NozomiAPI {
    static const String _url = "https://j.nozomi.la/";
    static const String _imageUrl = "https://w.nozomi.la/";
    static const String _indexUrl = "https://n.nozomi.la/index.nozomi";

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));

    NozomiAPI() {
        addSmartRetry(_client);
    }

    static String fullUrlFromPathFromHash(String hash, bool isVideo) {
        String hashString = fullPathFromHash(hash);
        String ext = (isVideo) ? ".webm" : ".webp";
        return "$_imageUrl$hashString$ext";
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 100, int page = 1}) async {
        // Neither the page index nor the limit of posts can be smaller or equal to 0.
        // We cap them to sensible values.
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;

        List<String> tagList = [];
        List<String> splitTags = (tags.isNotEmpty) ? tags.split(" ") : [];

        // We iterate through all the tags to generate the request file path for later.
        for (String tag in splitTags) {
            tagList.add("${_url}nozomi/$tag.nozomi");
        }

        // If the tag list is empty, we grab posts from the main index instead and we limit the post range.
        if (tagList.isEmpty) {
            tagList.add(_indexUrl);
        }

        Nokulog.d(tagList);

        var oldHeaders = Map<String, dynamic>.from(_client.options.headers);        
        _client.options.responseType = ResponseType.bytes;

        Map<String, List<int>> results = {};

        int byteStart = (page - 1) * limit * 4;
        int byteEnd = byteStart + limit * 4 - 1;

        _client.options.headers["Range"] = "bytes=$byteStart-";

        // If we only have a singular file, there is no problem with limiting it to the amount of posts we seek.
        if (tagList.length == 1) {
            _client.options.headers["Range"] += "$byteEnd";
        }

        Nokulog.d(_client.options.headers["Range"]);

        Executor tagExecutor = Executor(concurrency: 15);

        // We go through all the tags in the search query and collect the posts of the page.
        for (String tag in tagList) {
            if (!results.containsKey(tag)) {
                results[tag] = [];
            }
            
            tagExecutor.scheduleTask(() async {
                try {
                    Nokulog.d("Requesting $tag");
                    Response<Uint8List> response = await _client.get(tag);

                    Nokulog.d("Response: ${response.statusCode}");
                    Uint8List? data = response.data;

                    if (data == null) {
                        Nokulog.e("Data for tag \"$tag\" was null.");
                        return null;
                    }

                    int totalItems = data.length ~/ 4;

                    if (totalItems == 0) {
                        return null;
                    }

                    var buffer = ByteData.sublistView(data);
                    for (int i = 0; i < totalItems; i++) {
                        int value = buffer.getInt32(i * 4);
                        results[tag]!.add(value);
                    }

                } catch (e, stackTrace) {
                    Nokulog.e("Failed to fetch \"$tag\".", error: e, stackTrace: stackTrace);
                }
            });
        }

        await tagExecutor.join(withWaiting: true);
        await tagExecutor.close();

        final intersectionPosts = results.values.fold<Set<int>>(
            results.values.first.toSet(), 
            (a, b) => a.intersection(b.toSet())
        );

        if (intersectionPosts.isEmpty) return [];

        List<int> filteredPosts = intersectionPosts.toList();
        
        if (filteredPosts.length > limit) {
            filteredPosts = filteredPosts.sublist(0, limit);
        }

        Nokulog.d("filteredPosts: ${filteredPosts.length}");

        if (filteredPosts.isEmpty) {
            return [];
        }

        List<Map<String, dynamic>> posts = [];

        _client.options.headers = oldHeaders;
        _client.options.responseType = ResponseType.plain;

        Executor executor = Executor(concurrency: 15);

        for (int id in filteredPosts) {
            executor.scheduleTask(() async {
                var result = await getPost(id);
                if (result == null) return;
                posts.add(result);
            });
        }

        await executor.join(withWaiting: true);
        await executor.close();

        Nokulog.d("total posts: ${posts.length}");

        return posts;
    }

    Future<Map<String, dynamic>?> getPost(int postID, {bool withGender = true}) async {
        if (postID <= 0) {
            Nokulog.e("Post ID cannot be a value lower or equal to 0. Value: $postID");
            return null;
        }

        Map<String, dynamic> jsonData = {};

        try {
            String postPath = fullPathFromHash(postID.toString());
            Response<String> postRequest = await _client.get("${_url}post/$postPath.json", options: Options(responseType: ResponseType.plain));
            String? responseData = postRequest.data;

            if (responseData == null) return jsonData;

            jsonData = jsonDecode(responseData);

            // Get images
            List<dynamic> imageUrls = List.from(jsonData["imageurls"]);
            List<String> images = [];
            List<List<int>> dimensions = [];
            List<String> hashes = [];

            for (var image in imageUrls) {
                // Thanks to Dart's type checker, we need to create a new map from the original to have it properly type-casted.
                var imageData = Map<String, dynamic>.from(image);

                // Theoretically, is_video should always be a string, but I already have too many bad memories of hitomi.
                String isVideo = (imageData["is_video"] is! String) ? imageData["is_video"].toString() : imageData["is_video"];
                images.add(fullUrlFromPathFromHash(imageData["dataid"], isVideo.isNotEmpty));

                // Same thing with the dimensions of the image.
                int width = imageData["width"];
                int height = imageData["height"];

                dimensions.add([width, height]);

                hashes.add(imageData["dataid"]);
            }

            String thumbnail = thumbnailFromImageUrl(images.first, jsonData["type"].toString());

            List<String> tags = [];
            List<String> artistNames = [];

            if (jsonData["general"] != null) {
                List<dynamic> tagData = List.from(jsonData["general"]);
                for (var tagItem in tagData) {
                    var tag = Map<String, dynamic>.from(tagItem);

                    tags.add(tag["tag"]!);
                }
            }

            if (jsonData["artist"] != null) {
                List<dynamic> artists = List.from(jsonData["artist"]);

                for (var artist in artists) {
                    var artistData = Map<String, dynamic>.from(artist);

                    tags.add(artistData["tag"]!);
                    artistNames.add(artistData["tag"]!);
                }
            }

            List<dynamic> remaining = [];

            if (jsonData["copyright"] != null) {
                remaining.addAll(List.from(jsonData["copyright"]));
            }

            if (jsonData["character"] != null) {
                remaining.addAll(List.from(jsonData["character"]));
            }

            for (var item in remaining) {
                var itemData = Map<String, dynamic>.from(item);
                tags.add(itemData["tag"]!);
            }

            Map<String, dynamic> result = {
                "postID": (jsonData.containsKey("id") && jsonData["id"] != null) ? ((jsonData["id"] is String) ? int.tryParse(jsonData["id"]) : jsonData["id"]) : postID,
                "title": jsonData["title"],
                "images": images,
                "tags": tags,
                "dimensions": dimensions,
                "hashes": hashes,
                "artists": artistNames,
                "preview": thumbnail
            };

            return result;


        } catch (e, stacktrace) {
            Nokulog.e("Failed to fetch post with ID $postID.", error: e, stackTrace: stacktrace);
            Nokulog.e(jsonEncode(jsonData), error: e, stackTrace: stacktrace);
            return null;
        }
    }

    Future<List<Map<String, dynamic>>> searchComments({int? postID, int limit = 100, int page = 1}) async {
        return const [];
    }

    Future<Map<String, dynamic>?> getComment(int commentID, int postID) async {
        return null;
    }

    Future<List<Map<String, dynamic>>> getNotes(int postID) async {
        return const [];
    }
}