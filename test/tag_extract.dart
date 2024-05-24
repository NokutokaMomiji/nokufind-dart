
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nokufind/nokufind.dart';

const int maxRecursionLimit = 1000;
const String tagFilepath = "D:/Archivos de Usuario/Documentos/Nokubooru/tags.dat";

GZipCodec codec = GZipCodec(level: 9);
Finder finder = Finder()..addDefault();

Set<String> initialTags = <String>{};

Future<void> loadTags() async {
    var tagFile = File(tagFilepath);

    var data = await tagFile.readAsBytes();
    var decodedData = List<String>.from(jsonDecode(utf8.decode(codec.decode(data))));

    for (String tag in decodedData) {
        initialTags.add(tag);
    }

    print("Current number of tags: ${initialTags.length}");
}

Future<void> searchTag(String tag) async {
    print("Searching tag: $tag");
    var posts = await finder.searchPosts(tag, limit: 10000);
    print("first: ${posts.firstOrNull}");
    Set<String> newTags = {};

    for (Post post in posts) {
        for (String tag in post.tags) {
            if (initialTags.contains(tag)) {
                continue;
            }

            newTags.add(tag);
            initialTags.add(tag);
        }
    }

    print("New number of tags: ${initialTags.length}");

    List<Future> a = [];

    for (String tag in newTags) {
        a.add(searchTag(tag));
    }

    await Future.wait(a);
}

Future<void> saveTags() async {
    print("Final number of tags: ${initialTags.length}");
    var tagFile = File(tagFilepath);

    var encodedData = codec.encode(utf8.encode(jsonEncode(initialTags.toList())));

    await tagFile.writeAsBytes(encodedData);
}

void main() async {
    await loadTags();
    
    List<Future> a = [];

    for (String tag in initialTags) {
        a.add(searchTag(tag));
    }

    await Future.wait(a);

    await saveTags();
}