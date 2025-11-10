import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:nokufind/src/API/api_tools.dart";

import "../Utils/utils.dart";

String thumbnailFromImageUrl(String imageUrl, String originalFormat) {
    final String newDomain = imageUrl.replaceAll("w.nozomi.la", "qtn.gold-usergeneratedcontent.net").replaceAll("w.gold-usergeneratedcontent.net", "qtn.gold-usergeneratedcontent.net");
    final String ext = imageUrl.split(".").last;
    return newDomain.replaceAll(ext, "$originalFormat.webp");
}

String fullPathFromHash(String hash) {
    if (hash.length < 3) {
        return hash;
    }
    
    // Use RegExp to match the pattern
    final RegExp regExp = RegExp(r'^.*(..)(.)$');
    final RegExpMatch? match = regExp.firstMatch(hash);

    if (match != null) {
        final String part2 = match.group(2)!;
        final String part1 = match.group(1)!;
        return '$part2/$part1/$hash';
    }

    // If no match is found, return the original hash (this should not happen with the given pattern)
    return hash;
}

class NozomiAPI extends BaseAPI {
    static const String _url = "https://j.gold-usergeneratedcontent.net/";
    static const String _imageUrl = "https://w.gold-usergeneratedcontent.net/";
    static const String _indexUrl = "https://n.nozomi.la/index.nozomi";

    NozomiAPI() : super(
        Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)))
    ) {
        addSmartRetry(client);

        errors.listen((data) {
            if (data.url != null) {
                _logError("Failed URL: \"${data.url}\"\n${data.message}");
                return;
            }

            _logError(data.message, error: data.exception, stackTrace: data.stackTrace);
        });
    }

    static String fullUrlFromPathFromHash(String hash, bool isVideo, bool isGif) {
        final String hashString = fullPathFromHash(hash);
        final String ext = (isVideo) ? ".webm" : ((isGif) ? ".gif" : ".webp");

        return "${(isGif) ? _imageUrl.replaceFirst("w.", "g.") : _imageUrl}$hashString$ext";
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 100, int page = 1, CancelToken? cancelToken}) async {
        // Neither the page index nor the limit of posts can be smaller or equal to 0.
        // We cap them to sensible values.
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;

        final List<String> tagList = [];
        final List<String> negativeTagList = [];
        final List<String> splitTags = (tags.isNotEmpty) ? tags.split(" ") : [];

        // We separate positive tags from negative ones ("-tag") and generate request file paths.
        for (final tag in splitTags) {
            if (tag.startsWith("-") && tag.length > 1) {
                final negativeTag = tag.substring(1);

                negativeTagList.add("${_url}nozomi/$negativeTag.nozomi");
                continue;
            }
            
            if (tag.isNotEmpty) {
                tagList.add("${_url}nozomi/$tag.nozomi");    
            }
        }

        // If there are no positive tags, we grab posts from the main index instead.
        if (tagList.isEmpty) {
            tagList.add(_indexUrl);
        }

        _log(tagList);

        final oldHeaders = Map<String, dynamic>.from(client.options.headers);

        final int byteStart = (page - 1) * limit * 4;
        final int byteEnd = byteStart + limit * 4 - 1;

        client.options.headers["Range"] = "bytes=$byteStart-";

        // If we only have a singular positive file, limit it.
        if ((tagList.length + negativeTagList.length) == 1) {
            client.options.headers["Range"] += "$byteEnd";
        }

        _log(client.options.headers["Range"]);

        final CancelToken token = cancelToken ?? CancelToken();
        final Executor tagExecutor = Executor(concurrency: 15);

        final Map<String, List<int>> results = {};
        final Map<String, List<int>> negativeResults = {};

        bool errorHasOccurred = false;

        // Fetch ID lists for positive tags / index
        for (final String tag in tagList) {
            if (!results.containsKey(tag)) {
                results[tag] = [];
            }

            tagExecutor.scheduleTask(() async {
                if (token.isCancelled || errorHasOccurred) return;

                final result = await _fetchIDList(tag, cancelToken: cancelToken);

                if (result.isError) {
                    errorHasOccurred = true;
                    return;
                }

                results[tag]!.addAll(result.data!);
            });
        }

        // Fetch ID lists for negative tags
        for (final negativeTag in negativeTagList) {
            if (!negativeResults.containsKey(negativeTag)) {
                negativeResults[negativeTag] = [];
            }

            tagExecutor.scheduleTask(() async {
                if (token.isCancelled || errorHasOccurred) return;

                final result = await _fetchIDList(negativeTag, cancelToken: cancelToken);

                if (result.isError) {
                    errorHasOccurred = true;
                    return;
                }

                results[negativeTag]!.addAll(result.data!);
            });
        }

        await tagExecutor.join(withWaiting: true);
        await tagExecutor.close();

        if (errorHasOccurred) {
            return [];
        }

        // Compute intersection of all positive‐tag result sets
        final intersectionPosts = results.values.fold<Set<int>>(
            results.values.first.toSet(),
            (a, b) => a.intersection(b.toSet())
        );

        if (intersectionPosts.isEmpty) return [];

        // If there are negative tags, build the union of their ID sets and subtract
        Set<int> finalPosts = intersectionPosts;
        if (negativeResults.isNotEmpty) {
            final negativeUnion = negativeResults.values.fold<Set<int>>(
                <int>{},
                (a, b) => a.union(b.toSet())
            );
            finalPosts = intersectionPosts.difference(negativeUnion);
        }

        if (finalPosts.isEmpty) return [];

        List<int> filteredPosts = finalPosts.toList();
        if (filteredPosts.length > limit) {
            filteredPosts = filteredPosts.sublist(0, limit);
        }

        _log("filteredPosts: ${filteredPosts.length}");

        if (filteredPosts.isEmpty) {
            return [];
        }

        final List<Map<String, dynamic>> posts = [];

        client.options.headers = oldHeaders;
        client.options.responseType = ResponseType.plain;

        final Executor executor = Executor(concurrency: 15);

        for (final int id in filteredPosts) {
            executor.scheduleTask(() async {
                final result = await getPost(id);
                if (result == null) return;
                posts.add(result);
            });
        }

        await executor.join(withWaiting: true);
        await executor.close();

        _log("total posts: ${posts.length}");

        return posts;
    }

    Future<Map<String, dynamic>?> getPost(int postID, {bool withGender = true}) async {
        if (postID <= 0) {
            Nokulog.e("Post ID cannot be a value lower or equal to 0. Value: $postID");
            return null;
        }

        Map<String, dynamic> jsonData = {};

        try {
            final String postPath = fullPathFromHash(postID.toString());
            final APIResult<String> postRequest = await safeGET(
                "${_url}post/$postPath.json", 
                (raw) => raw,
                options: Options(responseType: ResponseType.plain)
            );
            
            if (postRequest.isError) {
                return null;
            }
            
            final String? responseData = postRequest.data;

            if (responseData == null) return null;

            jsonData = jsonDecode(responseData);

            // Get images
            final List<dynamic> imageUrls = List.from(jsonData["imageurls"]);
            final List<String> images = [];
            final List<List<int>> dimensions = [];
            final List<String> hashes = [];

            for (final image in imageUrls) {
                // Thanks to Dart's type checker, we need to create a new map from the original to have it properly type-casted.
                final imageData = Map<String, dynamic>.from(image);

                // Theoretically, is_video should always be a string, but I already have too many bad memories of hitomi.
                final String isVideo = (imageData["is_video"] is! String) ? imageData["is_video"].toString() : imageData["is_video"];
                final bool isGif = (imageData["type"] == "gif");

                images.add(fullUrlFromPathFromHash(imageData["dataid"], isVideo.isNotEmpty, isGif));

                // Same thing with the dimensions of the image.
                final int width = imageData["width"];
                final int height = imageData["height"];

                dimensions.add([width, height]);

                hashes.add(imageData["dataid"]);
            }

            final String thumbnail = thumbnailFromImageUrl(images.first, jsonData["type"].toString());

            final List<String> tags = [];
            final List<String> artistNames = [];

            if (jsonData["general"] != null) {
                final List<dynamic> tagData = List.from(jsonData["general"]);
                for (final tagItem in tagData) {
                    final tag = Map<String, dynamic>.from(tagItem);

                    tags.add(tag["tag"]!);
                }
            }

            if (jsonData["artist"] != null) {
                final List<dynamic> artists = List.from(jsonData["artist"]);

                for (final artist in artists) {
                    final artistData = Map<String, dynamic>.from(artist);
                    artistNames.add(artistData["tag"]!);
                }
            }

            final List<String> source = [];
            final List<String> character = [];

            if (jsonData["copyright"] != null) {
                final copyrightTags = List.from(jsonData["copyright"]);
                
                for (final item in copyrightTags) {
                    final itemData = Map<String, dynamic>.from(item);
                    source.add(itemData["tag"]!);
                }
            }

            if (jsonData["character"] != null) {
                final copyrightTags = List.from(jsonData["character"]);
                
                for (final item in copyrightTags) {
                    final itemData = Map<String, dynamic>.from(item);
                    character.add(itemData["tag"]!);
                }
            }

            final Map<String, dynamic> result = {
                "postID": (jsonData.containsKey("id") && jsonData["id"] != null) ? ((jsonData["id"] is String) ? int.tryParse(jsonData["id"]) : jsonData["id"]) : postID,
                "title": jsonData["title"],
                "images": images,
                "tags": tags,
                "series": source,
                "characters": character,
                "dimensions": dimensions,
                "hashes": hashes,
                "artists": artistNames,
                "preview": thumbnail
            };

            return result;


        } catch (e, stacktrace) {
            _logError("Failed to fetch post with ID $postID.", error: e, stackTrace: stacktrace);
            _logError(jsonEncode(jsonData), error: e, stackTrace: stacktrace);
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

    Future<APIResult<List<int>>> _fetchIDList(String url, {CancelToken? cancelToken}) async {
        return safeGETRaw<List<int>>(
            url,
            (raw) {
                final Uint8List bytes = raw;
                final ByteData buffer = ByteData.sublistView(bytes);
                final int count = bytes.length ~/ 4;

                return [for (int i = 0; i < count; i++) buffer.getInt32(i * 4)];
            },
            options: Options(
                responseType: ResponseType.bytes
            ),
            cancelToken: cancelToken,
        );
    }

    void _log(Object? message) {
        Nokulog.d("[NozomiAPI]: ${message.toString()}");
    }

    void _logError(String message, {Object? error, StackTrace? stackTrace}) {
        Nokulog.e("[NozomiAPI]: $message", error: error, stackTrace: stackTrace);
    }
}