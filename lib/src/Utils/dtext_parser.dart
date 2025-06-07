
/*class DTextParser {
    // Configuration
    static final _tagDefinitions = <String, _TagDef>{
        'b': _TagDef('<strong>', '</strong>'),
        'i': _TagDef('<em>', '</em>'),
        'u': _TagDef('<u>', '</u>'),
        's': _TagDef('<s>', '</s>'),
        'spoilers': _TagDef('<span class="spoiler">', '</span>'),
        'spoiler': _TagDef('<span class="spoiler">', '</span>'),
        'quote': _TagDef('<blockquote>', '</blockquote>'),
        'expand': _TagDef('<details><summary>', '</summary></details>'),
        'hr': _TagDef('<hr/>', ''),
        'code': _TagDef('<pre><code>', '</code></pre>'),
    };

    /// Entry point: converts [input] DText into sanitized HTML.
    static String parse(String input) {
        // 1. Escape HTML
        var text = _escapeHtml(input);

        // 2. Extract code blocks and raw HTML into placeholders
        final placeholders = <String, String>{};
        text = _extractBlocks(text, r'\[code\](.*?)\[/code\]', placeholders, wrapCode: true);
        text = _extractBlocks(text, r'<pre>(.*?)</pre>', placeholders);

        // 3. Line-based transforms (headers, lists, hr)
        text = _transformLines(text);

        // 4. Tokenize and parse remaining tags
        text = _parseTags(text);

        // 5. Auto-link URLs, wiki links, mentions, post refs
        text = _autoLink(text);

        // 6. Restore placeholders
        placeholders.forEach((key, val) {
            text = text.replaceAll(key, val);
        });

        return text;
    }

    // ---------- Private Helpers ----------

    static String _escapeHtml(String s) =>
        const HtmlEscape(HtmlEscapeMode.element).convert(s);

    // Extract blocks matching [code]...[/code] or raw HTML, replace with placeholder
    static String _extractBlocks(String text, String pattern,
        Map<String, String> placeholders,
        {bool wrapCode = false}) {
        final regex = RegExp(pattern, dotAll: true, caseSensitive: false);
        return text.replaceAllMapped(regex, (m) {
            final content = m.group(1)!;
            final escaped = wrapCode
                ? '<pre><code>${const HtmlEscape(HtmlEscapeMode.element).convert(content)}</code></pre>'
                : m[0]!;
            final key = '__DTextBlock${placeholders.length}__';
            placeholders[key] = escaped;
            return key;
        });
    }

    // Handle headers (h4., h5., h6.), horizontal rules, and lists
    static String _transformLines(String text) {
        final lines = text.split('\n');
        final out = <String>[];
        var inList = false;
        for (var line in lines) {
            if (line.startsWith('h4. ')) {
                out.add('<h4>${line.substring(4).trim()}</h4>');
            } else if (line.startsWith('h5. ')) {
                out.add('<h5>${line.substring(4).trim()}</h5>');
            } else if (line.startsWith('h6. ')) {
                out.add('<h6>${line.substring(4).trim()}</h6>');
            } else if (line.trim() == '[hr]') {
                out.add('<hr/>');
            } else if (line.startsWith('* ')) {
                if (!inList) {
                    inList = true;
                    out.add('<ul>');
                }
                final item = line.substring(2).trim();
                out.add('<li>$item</li>');
            } else {
                if (inList) {
                    out.add('</ul>');
                    inList = false;
                }
                out.add(line);
            }
        }
        if (inList) out.add('</ul>');
        return out.join('\n');
    }

    // Stack-based parser for nested tags
    static String _parseTags(String text) {
        final tokenRegex = RegExp(r'\[(/?)(\w+)(?:=([^\]]+))?\]');
        final out = StringBuffer();
        final stack = <_OpenTag>[];
        var lastIndex = 0;

        for (final m in tokenRegex.allMatches(text)) {
            out.write(text.substring(lastIndex, m.start));
            lastIndex = m.end;

            final isClosing = m.group(1) == '/';
            final tag = m.group(2)!.toLowerCase();
            final param = m.group(3);

            if (!isClosing && _tagDefinitions.containsKey(tag)) {
                // Opening tag
                final def = _tagDefinitions[tag]!;
                if (tag == 'expand') {
                    final title = param != null ? _escapeHtml(param) : 'Show';
                    out.write('<details><summary>$title</summary>');
                    stack.add(_OpenTag(tag, def.close));
                } else if (tag == 'hr') {
                    out.write(def.open);
                } else {
                    out.write(def.open);
                    stack.add(_OpenTag(tag, def.close));
                }
            } else if (isClosing && _tagDefinitions.containsKey(tag)) {
                // Closing tag
                if (stack.isNotEmpty && stack.last.name == tag) {
                    out.write(stack.removeLast().close);
                } else {
                    // Mismatched closing tag: render literally
                    out.write(_escapeHtml(m.group(0)!));
                }
            } else {
                // Unknown tag: render literally
                out.write(_escapeHtml(m.group(0)!));
            }
        }

        out.write(text.substring(lastIndex));
        // Close any unclosed tags
        while (stack.isNotEmpty) {
            out.write(stack.removeLast().close);
        }
        return out.toString();
    }

    // Auto-link various patterns
    static String _autoLink(String text) {
        // Markdown-style: [Text](URL)
        text = text.replaceAllMapped(
            RegExp(r'\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)', caseSensitive: false),
            (m) {
                final label = _escapeHtml(m.group(1)!);
                final href = m.group(2)!;
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$label</a>';
            });

        // Reverse markdown: [URL](Text)
        text = text.replaceAllMapped(
            RegExp(r'\[(https?:\/\/[^\s\]]+)\]\(([^)]+)\)', caseSensitive: false),
            (m) {
                final href = m.group(1)!;
                final label = _escapeHtml(m.group(2)!);
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$label</a>';
            });

        // BBCode: [url]URL[/url]
        text = text.replaceAllMapped(
            RegExp(r'\[url\](https?:\/\/[^\s\[]+)\[\/url\]', caseSensitive: false),
            (m) {
                final href = m.group(1)!;
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$href</a>';
            });

        // BBCode with label: [url=URL]Text[/url]
        text = text.replaceAllMapped(
            RegExp(r'\[url=(https?:\/\/[^\s\]]+)\](.*?)\[\/url\]', caseSensitive: false, dotAll: true),
            (m) {
                final href = m.group(1)!;
                final label = _escapeHtml(m.group(2)!);
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$label</a>';
            });

        // DText-style: "Text":[URL]
        text = text.replaceAllMapped(
            RegExp(r'"([^"]+)"\:\[(https?:\/\/[^\]]+)\]'),
            (m) {
                final label = _escapeHtml(m.group(1)!);
                final href = m.group(2)!;
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$label</a>';
            });

        // Raw HTML links (leave untouched)
        // No need to touch <a href=...>...</a>

        // Angle bracket links: <https://...>
        text = text.replaceAllMapped(
            RegExp(r'<(https?:\/\/[^>\s]+)>'),
            (m) {
                final href = m.group(1)!;
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$href</a>';
            });

        // Plain auto-link URLs
        text = text.replaceAllMapped(
            RegExp(r'(?<!["\(=])\b(https?:\/\/[^\s<>()\[\]]+)', caseSensitive: false),
            (m) {
                final href = m.group(1)!;
                return '<a href="$href" rel="noopener noreferrer" target="_blank">$href</a>';
            });

        return text;
    }
}

// Internal helper classes
class _TagDef {
    final String open;
    final String close;
    const _TagDef(this.open, this.close);
}

class _OpenTag {
    final String name;
    final String close;
    _OpenTag(this.name, this.close);
}*/

class DTextParser {
    static const String _baseUrl = 'https://danbooru.donmai.us';

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
            .replaceAll('[code]', '<code>')
            .replaceAll('[/code]', '</code>')
            .replaceAll('[nodtext]', '')
            .replaceAll('[/nodtext]', '');
    }

    static String _processBlockElements(String text) {
        return text
            .replaceAllMapped(RegExp(r'h4\. (.*)'), (m) => '<h4>${m[1]}</h4>')
            .replaceAllMapped(RegExp(r'h5\. (.*)'), (m) => '<h5>${m[1]}</h5>')
            .replaceAllMapped(RegExp(r'h6\. (.*)'), (m) => '<h6>${m[1]}</h6>')
            .replaceAll('[hr]', '<hr>')
            .replaceAll('[expand]', '<details>')
            .replaceAll('[/expand]', '</details>')
            .replaceAllMapped(RegExp(r'\[expand=([^\]]+)\]'), 
                (m) => '<details><summary>${m[1]}</summary>')
            .replaceAll('[table]', '<table>').replaceAll('[/table]', '</table>')
            .replaceAll('[tr]', '<tr>').replaceAll('[/tr]', '</tr>')
            .replaceAll('[td]', '<td>').replaceAll('[/td]', '</td>')
            .replaceAll('[th]', '<th>').replaceAll('[/th]', '</th>')
            .replaceAll('[quote]', '<blockquote>').replaceAll('[/quote]', '</blockquote>')
            .replaceAllMapped(RegExp(r'\* (.*)'), (m) => '<li>${m[1]}</li>')
            .replaceAllMapped(RegExp(r'(\n<li>.*)+'), 
                (m) => '<ul>${m[0]}</ul>'.replaceAll('\n', ''));
    }

    static String _processLinks(String text) {
        return text
            .replaceAllMapped(RegExp(r'"(.+?)":\[(.*?)\]'), (m) {
                final url = m[2]!._normalizeUrl();
                return '<a href="$url">${m[1]}</a>';
            })
            .replaceAllMapped(RegExp(r'\[(.+?)\]\((.*?)\)'), (m) {
                final url = m[2]!._normalizeUrl();
                return '<a href="$url">${m[1]}</a>';
            })
            .replaceAllMapped(RegExp(r'{{(.*?)}}'), (m) {
                final parts = m[1]!.split('|');
                final tag = parts[0].replaceAll(' ', '+');
                final text = parts.length > 1 ? parts[1] : m[1];
                return '<a href="$_baseUrl/posts?tags=$tag">$text</a>';
            })
            .replaceAllMapped(RegExp(r'@(\w+)'), 
                (m) => '<a href="$_baseUrl/users/${m[1]}">@${m[1]}</a>');
    }

    static String _processWikiLinks(String text) {
        return text.replaceAllMapped(RegExp(r'\[\[(.*?)\]\]'), (m) {
            final parts = m[1]!.split('|');
            var path = parts[0].replaceAll(' ', '_').toLowerCase();
            final displayText = parts.length > 1 ? parts[1] : parts[0];
            
            if (path.contains('#')) {
                final anchorParts = path.split('#');
                path = '${anchorParts[0]}#dtext-${anchorParts[1].toLowerCase()}';
            }
            
            return '<a href="$_baseUrl/wiki_pages/$path">$displayText</a>';
        });
    }

    static String _processIdBasedLinks(String text) {
        return text.replaceAllMapped(RegExp(r'(\w+) #(\d+)'), (m) {
            final type = m[1]!;
            final id = m[2]!;
            final path = switch (type) {
                'post' => 'posts',
                'pool' => 'pools',
                'user' => 'users',
                'artist' => 'artists',
                'forum' => 'forum_posts',
                'comment' => 'comments',
                _ => '${type}s',
            };
            return '<a href="$_baseUrl/$path/$id">${m[0]}</a>';
        });
    }

    static String _processBasicFormatting(String text) {
        return text
            .replaceAll('[b]', '<strong>').replaceAll('[/b]', '</strong>')
            .replaceAll('[i]', '<em>').replaceAll('[/i]', '</em>')
            .replaceAll('[u]', '<u>').replaceAll('[/u]', '</u>')
            .replaceAll('[s]', '<s>').replaceAll('[/s]', '</s>')
            .replaceAll('[spoiler]', '<span class="spoiler">')
            .replaceAll('[/spoiler]', '</span>')
            .replaceAll('[tn]', '<span class="tn">').replaceAll('[/tn]', '</span>');
    }

    static String _processLineBreaks(String text) {
        return text.replaceAll('[br]', '<br>');
    }

    static String _processParagraphs(String text) {
        return text
            .split('\n\n')
            .map((p) => p.trim().isNotEmpty ? '<p>${p._replaceInlineBreaks()}</p>' : '')
            .join('\n');
    }
}

extension _StringExtensions on String {
    String _normalizeUrl() {
        final uri = Uri.tryParse(this);
        if (uri == null) return this;
        
        if (uri.host.isEmpty) {
            return Uri.parse('${DTextParser._baseUrl}${uri.path}').toString();
        }
        return uri.toString().replaceAll('[', '%5B').replaceAll(']', '%5D');
    }

    String _replaceInlineBreaks() {
        return replaceAll('\n', '<br>');
    }
}