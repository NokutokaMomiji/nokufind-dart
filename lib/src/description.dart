import 'dart:convert';
import 'package:html2md/html2md.dart' as html2md;

class Description {
    final Map<String, dynamic> _descriptionData = {};
    late DateTime _createdDatetime;

    Description({
        required int postID,
        String? originalTitle,
        required String originalDescription,
        String? translatedTitle,
        String? translatedDescription,
        required String source,
        required DateTime createdAt
    }) {
        _descriptionData["post_id"] = postID;
        _descriptionData["original_title"] = (originalTitle ?? "").isEmpty ? null : originalTitle;
        _descriptionData["original_description"] = (originalDescription).isEmpty ? null : originalDescription;
        _descriptionData["translated_title"] = (translatedTitle ?? "").isEmpty ? null : translatedTitle;
        _descriptionData["translated_description"] = (translatedDescription ?? "").isEmpty ? null : translatedDescription;
        _descriptionData["source"] = source;
        _descriptionData["created_at"] = createdAt.toUtc().millisecondsSinceEpoch;

        _createdDatetime = createdAt;
    }

    @override
    String toString() {
        return jsonEncode(_descriptionData);
    }

    String? getTitle({bool preferTranslated = true, bool asMarkdown = false}) {
        final String? title = (preferTranslated) ? (translatedTitle ?? originalTitle) : (originalTitle ?? translatedTitle);

        if (title == null || !asMarkdown) return title;

        return html2md.convert(title.replaceAll("\n", "<br>"));
    }

    String? getDescription({bool preferTranslated = true, bool asMarkdown = false}) {
        final String? description = (preferTranslated) ? (translatedDescription ?? originalDescription) : (originalDescription ?? translatedTitle);

        if (description == null || !asMarkdown) return description;

        return html2md.convert(description.replaceAll("\n", "<br>"));
    }

    Map<String, dynamic> toJson() => Map<String, dynamic>.from(_descriptionData);

    int get postID => _descriptionData["post_id"];
    String? get originalTitle => _descriptionData["original_title"];
    String? get originalDescription => _descriptionData["original_description"];
    String? get translatedTitle => _descriptionData["translated_title"];
    String? get translatedDescription => _descriptionData["translated_description"];
    String get source => _descriptionData["source"];
    DateTime get createdAt => _createdDatetime;
}