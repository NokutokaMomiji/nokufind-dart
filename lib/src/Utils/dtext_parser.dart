
class DTextParser {
    static const String _baseUrl = "https://danbooru.donmai.us";

    static String parse(String input) {
        var result = _processCodeBlocks(input);
        
        result = _processBlockElements(result);
        result = _processLinks(result);
        result = _processWikiLinks(result);
        result = _processIdBasedLinks(result);
        result = _processBasicFormatting(result);
        result = _processLineBreaks(result);
        result = _processParagraphs(result);

        return result;
    }

    static String _processCodeBlocks(String text) {
        return text
            .replaceAll("[code]", "<code>")
            .replaceAll("[/code]", "</code>")
            .replaceAll("[nodtext]", "")
            .replaceAll("[/nodtext]", "");
    }

    static String _processBlockElements(String text) {
        return text
            .replaceAllMapped(RegExp(r"h4\. (.*)"), (m) => "<h4>${m[1]}</h4>")
            .replaceAllMapped(RegExp(r"h5\. (.*)"), (m) => "<h5>${m[1]}</h5>")
            .replaceAllMapped(RegExp(r"h6\. (.*)"), (m) => "<h6>${m[1]}</h6>")
            .replaceAll("[hr]", "<hr>")
            .replaceAll("[expand]", "<details>")
            .replaceAll("[/expand]", "</details>")
            .replaceAllMapped(RegExp(r"\[expand=([^\]]+)\]"), 
                (m) => "<details><summary>${m[1]}</summary>")
            .replaceAll("[table]", "<table>").replaceAll("[/table]", "</table>")
            .replaceAll("[tr]", "<tr>").replaceAll("[/tr]", "</tr>")
            .replaceAll("[td]", "<td>").replaceAll("[/td]", "</td>")
            .replaceAll("[th]", "<th>").replaceAll("[/th]", "</th>")
            .replaceAll("[quote]", "<blockquote>").replaceAll("[/quote]", "</blockquote>")
            .replaceAllMapped(RegExp(r"\* (.*)"), (m) => "<li>${m[1]}</li>")
            .replaceAllMapped(RegExp(r"(\n<li>.*)+"), 
                (m) => "<ul>${m[0]}</ul>".replaceAll("\n", ""));
    }

    static String _processLinks(String text) {
        return text
            .replaceAllMapped(RegExp(r'"(.+?)":\[(.*?)\]'), (m) {
                final url = m[2]!._normalizeUrl();
                return "<a href=\"$url\">${m[1]}</a>";
            })
            .replaceAllMapped(RegExp(r'\[(.+?)\]\((.*?)\)'), (m) {
                final url = m[2]!._normalizeUrl();
                return "<a href=\"$url\">${m[1]}</a>";
            })
            .replaceAllMapped(RegExp(r"{{(.*?)}}"), (m) {
                final parts = m[1]!.split('|');
                final tag = parts[0].replaceAll(' ', '+');
                final text = parts.length > 1 ? parts[1] : m[1];
                return "<a href=\"$_baseUrl/posts?tags=$tag\">$text</a>";
            })
            .replaceAllMapped(RegExp(r"@(\w+)"), 
                (m) => "<a href=\"$_baseUrl/users/${m[1]}\">@${m[1]}</a>");
    }

    static String _processWikiLinks(String text) {
        return text.replaceAllMapped(RegExp(r"\[\[(.*?)\]\]"), (m) {
            final parts = m[1]!.split('|');
            var path = parts[0].replaceAll(' ', '_').toLowerCase();
            final displayText = parts.length > 1 ? parts[1] : parts[0];
            
            if (path.contains('#')) {
                final anchorParts = path.split('#');
                path = "${anchorParts[0]}#dtext-${anchorParts[1].toLowerCase()}";
            }
            
            return "<a href=\"$_baseUrl/wiki_pages/$path\">$displayText</a>";
        });
    }

    static String _processIdBasedLinks(String text) {
        return text.replaceAllMapped(RegExp(r"(\w+) #(\d+)"), (m) {
            final type = m[1]!;
            final id = m[2]!;
            final path = switch (type) {
                "post" => "posts",
                "pool" => "pools",
                "user" => "users",
                "artist" => "artists",
                "forum" => "forum_posts",
                "comment" => "comments",
                _ => "${type}s",
            };
            return "<a href=\"$_baseUrl/$path/$id\">${m[0]}</a>";
        });
    }

    static String _processBasicFormatting(String text) {
        return text
            .replaceAll("[b]", "<strong>").replaceAll("[/b]", "</strong>")
            .replaceAll("[i]", "<em>").replaceAll("[/i]", "</em>")
            .replaceAll("[u]", "<u>").replaceAll("[/u]", "</u>")
            .replaceAll("[s]", "<s>").replaceAll("[/s]", "</s>")
            .replaceAll("[spoiler]", "<span class=\"spoiler\">")
            .replaceAll("[/spoiler]", "</span>")
            .replaceAll("[tn]", "<span class=\"tn\">").replaceAll("[/tn]", "</span>");
    }

    static String _processLineBreaks(String text) {
        return text.replaceAll("[br]", "<br>");
    }

    static String _processParagraphs(String text) {
        return text
            .split("\n\n")
            .map((p) => p.trim().isNotEmpty ? "<p>${p._replaceInlineBreaks()}</p>" : "")
            .join("\n");
    }
}

extension _StringExtensions on String {
    String _normalizeUrl() {
        final uri = Uri.tryParse(this);
        if (uri == null) return this;
        
        if (uri.host.isEmpty) {
            return Uri.parse("${DTextParser._baseUrl}${uri.path}").toString();
        }
        return uri.toString().replaceAll('[', "%5B").replaceAll(']', "%5D");
    }

    String _replaceInlineBreaks() {
        return replaceAll("\n", "<br>");
    }
}