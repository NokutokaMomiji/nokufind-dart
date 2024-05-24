import 'dart:convert';
import 'package:html2md/html2md.dart' as html2md;

class Note {
    final Map<String, dynamic> _noteData = {};

    Note({
        required int noteID,
        required DateTime createdAt,
        required int x,
        required int y,
        required int width,
        required int height,
        required String body,
        required String source,
        required int postID,
    }) {
        _noteData["note_id"] = noteID;
        _noteData["created_at"] = createdAt.toUtc().millisecondsSinceEpoch ~/ 1000;
        _noteData["x"] = x;
        _noteData["y"] = y;
        _noteData["width"] = width;
        _noteData["height"] = height;
        _noteData["body"] = body;
        _noteData["source"] = source;
        _noteData["post_id"] = postID;
    }

    @override
    String toString() {
        return jsonEncode(_noteData);
    }

    String bodyToMarkdown() {
        return html2md.convert(_noteData['body']);
    }

    dynamic operator [](String key) {
        return _noteData[key];
    }

    int get noteID => _noteData["note_id"];

    String get createdAt => _noteData["created_at"];

    int get x => _noteData["x"];

    int get y => _noteData["y"];

    int get width => _noteData["width"];

    int get height => _noteData["height"];

    String get body => _noteData["body"];

    String get source => _noteData["source"];

    int get postID => _noteData["post_id"];
}