import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:dio_http2_adapter/dio_http2_adapter.dart";
import "package:executor/executor.dart";
import "package:nokufind/src/Utils/hitomi_utils.dart";

import "../Utils/utils.dart";

class HitomiAPI {
    static const String _url = "https://ltn.gold-usergeneratedcontent.net/";
    static const String _galleryUrl = "https://ltn.gold-usergeneratedcontent.net/galleries/";
    static const List<String> _validTagTypes = ["character", "series", "artist", "group", "type"];

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

        final List<String> tagList = [];
        final List<String> splitTags = (tags.isNotEmpty) ? tags.split(" ") : [];

        // We iterate through all the tags to generate the request file path for later.
        for (final String tag in splitTags) {
            final String actualTag = tag.replaceAll("_", " ");

            if (tag.startsWith("female") || tag.startsWith("male")){
                tagList.add("tag/$actualTag-all.nozomi");
                continue;
            }

            if (tag.startsWith("language")) {
                final String language = tag.split(":").last;

                tagList.add("index-$language.nozomi");
                continue;
            }

            final List<String> splitTag = actualTag.split(":");
            final String tagType = splitTag.first;
            final String tagValue = splitTag.last;

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


        final oldHeaders = Map<String, dynamic>.from(_client.options.headers);        
        _client.options.responseType = ResponseType.bytes;

        final Map<String, List<int>> results = {};

        final int byteStart = (page - 1) * limit * 4;
        final int byteEnd = byteStart + limit * 4 - 1;

        _client.options.headers["Range"] = "bytes=$byteStart-";

        // If we only have a singular file, there is no problem with limiting it to the amount of posts we seek.
        if (tagList.length == 1) {
            _client.options.headers["Range"] += "$byteEnd";
        }

        Nokulog.d(_client.options.headers["Range"]);

        final Executor tagExecutor = Executor(concurrency: 15);

        // We go through all the tags in the search query and collect the posts of the page.
        for (final String tag in tagList) {
            if (!results.containsKey(tag)) {
                results[tag] = [];
            }
            
            tagExecutor.scheduleTask(() async {
                try {
                    Nokulog.d("Requesting $_url$tag");
                    final Response<Uint8List> response = await _client.get("$_url$tag");

                    Nokulog.d("Response: ${response.statusCode}");
                    final Uint8List? data = response.data;

                    if (data == null) {
                        Nokulog.e("Data for tag \"$tag\" was null.");
                        return null;
                    }

                    final int totalItems = data.length ~/ 4;

                    if (totalItems == 0) {
                        return null;
                    }

                    final buffer = ByteData.sublistView(data);
                    for (int i = 0; i < totalItems; i++) {
                        final int value = buffer.getInt32(i * 4);
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

        final List<Map<String, dynamic>> posts = [];

        _client.options.headers = oldHeaders;
        _client.options.responseType = ResponseType.plain;

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

            final Response<String> response = await _client.get("$_galleryUrl$postID.js");
            final String? rawData = response.data;
            
            if (rawData == null || !rawData.contains("var galleryinfo = ")) {
                Nokulog.e("Either rawData is null or it doesn't contain valid info.");
                return null;
            }

            jsonData = jsonDecode(rawData.replaceAll("var galleryinfo = ", ""));
            final List<HitomiFile> files = (jsonData["files"] as List<dynamic>).map((element) => HitomiFile.fromJson(postID, Map<String, dynamic>.from(element))).toList();

            //Nokulog.d(jsonEncode(jsonData));
            //Nokulog.d("======================================");

            final String? videoUrl = jsonData["video"];

            if (_common == null) {
                await configureCommon();
            }

            final List<String> images = [];
            final List<String> hashes = [];
            final List<List<int>> dimensions = [];

            for (final file in files) {
                //images.add(_common!.urlFromUrlFromHash(postID.toString(), file, "webp", "", "a"));
                images.add(_common!.imageUrlFromImage(postID.toString(), file, preferWebp: preferWebp));
                hashes.add(file.hash);
                dimensions.add([file.width, file.height]);
            }

            final List<String> tags = [
                if (jsonData["language"] != null) "language:${jsonData["language"]}"
            ];

            for (final tag in (jsonData["tags"] as List)) {
                final currentTag = Map<String, dynamic>.from(tag);
                
                final String? male = (currentTag["male"] is int) ? currentTag["male"].toString() : currentTag["male"];
                final String? female = (currentTag["female"] is int) ? currentTag["female"].toString() : currentTag["female"];

                String gender = "tag:";
                
                if (male != null || female != null) {
                    gender = (male != null && male.isEmpty) ? "female:" : "male:";
                }
                
                tags.add("$gender${currentTag['tag']!.replaceAll(' ', '_')}");
            }

            final List<dynamic>? artists = jsonData["artists"];
            final List<dynamic>? characters = jsonData["characters"];
            final List<dynamic>? parodies = jsonData["parodys"];
            
            final List<String> artistNames = [];
            final List<String> artistTags = [];
            final List<String> characterTags = [];
            final List<String> parodyTags = [];
            
            if (artists != null) {
                for (final artist in artists) {
                    artistTags.add("artist:${artist["artist"].replaceAll(" ", "_")}");
                    artistNames.add(artist["artist"]);
                }
            }

            if (characters != null) {
                for (final character in characters) {
                    characterTags.add("character:${character["character"].replaceAll(" ", "_")}");
                }
            }

            if (parodies != null) {
                for (final parody in parodies) {
                    parodyTags.add("series:${parody["parody"].replaceAll(" ", "_")}");
                }
            }

            final Map<String, dynamic> result = {
                "postID": (jsonData.containsKey("id") && jsonData["id"] != null) ? ((jsonData["id"] is String) ? int.tryParse(jsonData["id"]) : jsonData["id"]) : postID,
                "title": jsonData["title"],
                "images": (videoUrl == null) ? images : ["https:$videoUrl"],
                "tags": tags,
                "artists": artistTags,
                "characters": characterTags,
                "parodies": parodyTags,
                "dimensions": dimensions,
                "hashes": hashes,
                "authors": artistNames,
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
                final Response<String> ggreq = await _client.get(
                    "https://ltn.gold-usergeneratedcontent.net/gg.js",
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