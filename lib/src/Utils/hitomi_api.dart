import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:nokufind/src/Utils/hitomi_utils.dart";

import "../Utils/utils.dart";

class HitomiAPI {
    static const String _url = "https://ltn.hitomi.la/";
    static const String _galleryUrl = "https://ltn.hitomi.la/galleries/";
    static const List<String> _validTagTypes = ["character", "series", "artist", "group"];

    final Dio _client = Dio()..httpClientAdapter = Http2Adapter(ConnectionManager(idleTimeout: const Duration(seconds: 15)));
    static Common? _common;
    bool preferWebp;

    HitomiAPI({this.preferWebp = true}) {
        addSmartRetry(_client);
        configureCommon();
    }

    Future<List<Map<String, dynamic>>> searchPosts(String tags, {int limit = 100, int page = 0}) async {
        // Neither the page index nor the limit of posts can be smaller or equal to 0.
        // We cap them to sensible values.
        if (page <= 0) page = 1;
        if (limit <= 0) limit = 100;

        List<String> tagList = [];
        List<String> splitTags = (tags.isNotEmpty) ? tags.split(" ") : [];

        // We iterate through all the tags to generate the request file path for later.
        for (String tag in splitTags) {
            String actualTag = tag.replaceAll("_", " ");

            if (tag.startsWith("female") || tag.startsWith("male")){
                tagList.add("tag/$actualTag-all.nozomi");
                continue;
            }

            if (tag.startsWith("language")) {
                String language = tag.split(":").last;

                tagList.add("index-$language.nozomi");
                continue;
            }

            List<String> splitTag = actualTag.split(":");
            String tagType = splitTag.first;
            String tagValue = splitTag.last;

            if (_validTagTypes.contains(tagType)) {
                tagList.add("$tagType/$tagValue-all.nozomi");
                continue;
            }

            tagList.add("tag/female:$actualTag-all.nozomi");
            tagList.add("tag/male:$actualTag-all.nozomi");
            tagList.add("tag/$actualTag-all.nozomi");
        }

        // If the tag list is empty, we grab posts from the main index instead and we limit the post range.
        if (tagList.isEmpty) {
            tagList.add("index-all.nozomi");
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
                    Nokulog.d("Requesting $_url$tag");
                    Response<Uint8List> response = await _client.get("$_url$tag");

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
            _client.options.responseType = ResponseType.plain;

            Response<String> response = await _client.get("$_galleryUrl$postID.js");
            String? rawData = response.data;
            
            if (rawData == null || !rawData.contains("var galleryinfo = ")) {
                Nokulog.e("Either rawData is null or it doesn't contain valid info.");
                return null;
            }

            jsonData = jsonDecode(rawData.replaceAll("var galleryinfo = ", ""));
            List<HitomiFile> files = (jsonData["files"] as List<dynamic>).map((element) => HitomiFile.fromJson(postID, Map<String, dynamic>.from(element))).toList();

            //Nokulog.d(jsonEncode(jsonData));
            //Nokulog.d("======================================");

            String? videoUrl = jsonData["video"];

            if (_common == null) {
                await configureCommon();
            }

            List<String> images = [];
            List<String> hashes = [];
            List<List<int>> dimensions = [];

            for (var file in files) {
                //images.add(_common!.urlFromUrlFromHash(postID.toString(), file, "webp", "", "a"));
                images.add(_common!.imageUrlFromImage(postID.toString(), file, preferWebp: preferWebp));
                hashes.add(file.hash);
                dimensions.add([file.width, file.height]);
            }

            List<String> tags = [
                if (jsonData["language"] != null) "language:${jsonData["language"]}"
            ];

            for (var tag in (jsonData["tags"] as List)) {
                var currentTag = Map<String, dynamic>.from(tag);
                
                String? male = (currentTag["male"] is int) ? currentTag["male"].toString() : currentTag["male"];
                String? female = (currentTag["female"] is int) ? currentTag["female"].toString() : currentTag["female"];

                String gender = "tag:";
                
                if (male != null || female != null) {
                    gender = (male != null && male.isEmpty) ? "female:" : "male:";
                }
                
                tags.add("$gender${currentTag['tag']!.replaceAll(' ', '_')}");
            }

            List<dynamic>? artists = jsonData["artists"];
            List<dynamic>? characters = jsonData["characters"];
            List<dynamic>? parodies = jsonData["parodys"];
            
            List<String> artistNames = [];
            if (artists != null) {
                for (var artist in artists) {
                    tags.add("artist:${artist["artist"].replaceAll(" ", "_")}");
                    artistNames.add(artist["artist"].replaceAll(" ", "_"));
                }
            }

            if (characters != null) {
                for (var character in characters) {
                    tags.add("character:${character["character"].replaceAll(" ", "_")}");
                }
            }

            if (parodies != null) {
                for (var parody in parodies) {
                    tags.add("series:${parody["parody"].replaceAll(" ", "_")}");
                }
            }

            Map<String, dynamic> result = {
                "postID": (jsonData.containsKey("id") && jsonData["id"] != null) ? ((jsonData["id"] is String) ? int.tryParse(jsonData["id"]) : jsonData["id"]) : postID,
                "title": jsonData["title"],
                "images": (videoUrl == null) ? images : ["https:$videoUrl"],
                "tags": tags,
                "dimensions": dimensions,
                "hashes": hashes,
                "artists": artistNames,
                "preview": _common!.getThumbnail(postID.toString(), files.first)
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

    Future<void> configureCommon() async {
        for (int i = 0; i < 10; i++) {
            try {
                Response<String> ggreq = await _client.get(
                    "https://ltn.hitomi.la/gg.js",
                    options: Options(
                        responseType: ResponseType.plain
                    )
                );
                _common = Common(ggreq.data!);
                return;
            } catch (e, stackTrace) {
                Nokulog.e("Failed to fetch gg.js.", error: e, stackTrace: stackTrace);
            }
        }
    }
}