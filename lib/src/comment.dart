import 'dart:convert';
import 'package:html2md/html2md.dart' as html2md;

class Comment {
    final Map<String, dynamic> _commentData = {};
    late DateTime _createdDatetime;

    Comment({
        required int commentID,
        required int postID,
        required int creatorID,
        required String creator,
        String? creatorAvatar,
        required String body,
        required String source,
        required DateTime createdAt,
    }) {
        _commentData["comment_id"] = commentID;
        _commentData["post_id"] = postID;
        _commentData["creator_id"] = creatorID;
        _commentData["creator"] = creator;
        _commentData["creator_avatar"] = creatorAvatar;
        _commentData["body"] = body;
        _commentData["source"] = source;
        _commentData["created_at"] = createdAt.toUtc().millisecondsSinceEpoch ~/ 1000;

        _createdDatetime = createdAt;
    }

    @override
    String toString() {
        return jsonEncode(_commentData);
    }

    String bodyToMarkdown() {
        return html2md.convert(_commentData['body'].replaceAll("[quote]", "[blockquote]").replaceAll("[/quote]", "[/blockquote]"));
    }

    int operator [](String key) {
        return _commentData[key];
    }

    int get commentID => _commentData["comment_id"];

    int get postID => _commentData["post_id"];

    int get creatorID => _commentData["creator_id"];

    String get creator => _commentData["creator"];

    String? get creatorAvatar => _commentData["creator_avatar"];

    String get body => _commentData["body"];

    String get source => _commentData["source"];

    int get createdAt => _commentData["created_at"];

    DateTime get createdDatetime => _createdDatetime;
}
