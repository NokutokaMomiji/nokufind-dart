import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:logger/logger.dart';

const String userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 OPR/109.0.0.0";
const String pixivReferer = "https://app-api.pixiv.net/";

class ErrorFilter extends LogFilter {
    @override
    bool shouldLog(LogEvent event) {
        var shouldLog = false;
        
        assert(() {
            if (event.level.value >= level!.value) {
                shouldLog = true;
            }
            return true;
        }());

        if (event.level.value >= Level.warning.value && event.level.value != Level.off.value) {
            return true;
        }

        return shouldLog;
    }
}

class ListLog extends LogOutput {
    @override
    void output(OutputEvent event) {
        Nokulog.log.addAll(event.lines);
        event.lines.forEach(print);
    }

}

class Nokulog {
    static List<String> log = [];

    static LogFilter _filter = ErrorFilter();
    static LogPrinter? _printer = PrettyPrinter();

    static Logger logger = Logger(
        filter: ErrorFilter(),
        printer: PrettyPrinter(),
        output: ListLog()
    );

    static set logErrors(bool value) {
        Nokulog._filter = (value) ? ErrorFilter() : DevelopmentFilter();
        logger = Logger(
            filter: Nokulog._filter,
            printer: Nokulog._printer,
            output: ListLog()
        );
    }

    static set logPretty(bool value) {
        Nokulog._printer = (value) ? PrettyPrinter() : null;
        logger = Logger(
            filter: Nokulog._filter,
            printer: Nokulog._printer,
            output: ListLog()
        );
    }
}

String mapToPairedString(Map<dynamic, dynamic> map, {String separator = '&', String unifier = '='}) {
    List<String> pairs = [];

    map.forEach((key, value) {
        pairs.add("$key$unifier$value");
    });

    return pairs.join(separator);
}

Map<String, String> pairedStringToMap(String str, {String separator = '&', String unifier = '='}) {
    Map<String, String> pairs = {};

    str.split(separator).forEach((element) {
        var elementSplit = element.split(unifier);

        if (elementSplit.length < 2) return;

        pairs[elementSplit[0]] = elementSplit[1]; 
    });

    return pairs;
}

List<String> parseTags(String tags) {
    String currentText = "";
    List<String> tagList = [];
    int numOfParenthesis = 0;

    for (int index = 0; index < tags.length; index++) {
        var char = tags[index];
        if (char == " " && numOfParenthesis == 0) {
            tagList.add(currentText);
            currentText = "";
            continue;
        }

        numOfParenthesis += char == '(' ? 1 : (char == ')' ? -1 : 0);

        if (numOfParenthesis < 0) {
            throw FormatException("Unmatched closing parenthesis found in tags.\n    $tags\n    ${'~' * index}^");
        }

        currentText += char;
    }

    tagList.add(currentText);
    return tagList;
}

T? get<T>(List<T?> list, int index, {T? defaultValue}) {
    if (index >= list.length) {
        return defaultValue;
    }

    return list[index];
}

String trimLeft(String text, String? chars) {
    if (chars == null) return text.trimLeft();

    int start = 0;

    for (String char in chars.characters) {
        if (!chars.contains(char)) break;
        start += 1;
    }

    return text.substring(start);
}

String trimRight(String text, String? chars) {
    if (chars == null) return text.trimRight();

    int end = text.length;

    for (int i = text.length - 1; i > 0; i--) {
        if (!chars.contains(text[i])) {
            end = i + 1;
            break;
        }
    }

    return text.substring(0, end);
}

String trim(String text, String? chars) {
    if (chars == null) return text.trim();

    return trimRight(trimLeft(text, chars), chars);
}

String calculateMD5(Uint8List imageData) {
    var imageMD5 = md5.convert(imageData);

    return imageMD5.toString();
}

String toTitle(String string) {
    return string.substring(0, 1).toUpperCase() + string.substring(1);
}

void addSmartRetry(Dio dio) {
    dio.interceptors.add(
        RetryInterceptor(
            dio: dio,
            logPrint: Nokulog.logger.e,
            retries: 5,
            retryDelays: [
                const Duration(seconds: 1),
                const Duration(seconds: 2),
                const Duration(seconds: 2),
                const Duration(seconds: 3),
                const Duration(seconds: 5),
            ]
        )
    );
}

List<String> splitIntoPieces(String string) {
    string = string.toLowerCase().replaceAll(')', '').replaceAll('https://', '').replaceAll('//', '/').replaceAll('_', '');

    final List<String> parts = [];
    String current = "";

    for (int i = 0; i < string.length; i++) {
        var char = string[i];

        if (char == '(' || char == '/') {
            if (current.isEmpty) continue;

            if (current.startsWith("@")) {
                parts.insert(0, current.substring(1, current.length));
                current = "";
                continue;
            }

            parts.add(current);
            current = "";
            continue;
        }

        current += char;
    }

    if (current.isNotEmpty) {
        parts.add(current);
    }

    return parts;
}

String? checkForPotentialAuthor(String tag, String url) {
    final List<String> tagParts = splitIntoPieces(tag);
    final List<String> urlParts = splitIntoPieces(url);

    for (var tagPart in tagParts) {
        for (var urlPart in urlParts) {
            if (tagPart == urlPart) return tagPart;
        }
    }

    return null;
}

List<String> getPotentialAuthors(List<String> tags, List<String> sources) {
    if (tags.isEmpty || sources.isEmpty) {
        return const [];
    }

    final List<String> authors = [];

    for (var tag in tags) {
        for (var source in sources) {
            var check = checkForPotentialAuthor(tag, source);
            if (check == null) continue;
            authors.add(check);
        }
    }

    return authors;
}