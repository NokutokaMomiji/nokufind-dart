import 'dart:collection';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:logger/logger.dart';

const String userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 OPR/119.0.0.0";
const String pixivReferer = "https://app-api.pixiv.net/";

enum NokulogMode {
    base,
    all,
    errors,
    onlyErrors,
    off
}

enum NokulogEventType {
    debug,
    info,
    warning,
    error,
    trace
}

class ErrorFilter extends LogFilter {
    @override
    bool shouldLog(LogEvent event) {
        switch (Nokulog.mode) {
            case NokulogMode.base:

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
        
            case NokulogMode.all:
            return true;
            
            case NokulogMode.errors:
            if (event.level.value >= Level.warning.value && event.level.value != Level.off.value) {
                return true;
            }
            break;

            case NokulogMode.onlyErrors:
            return (event.level.value == Level.error.value);

            case NokulogMode.off:
            return false;
        }

        return false;
    }
}

class NokulogEvent {
    final NokulogEventType eventType;
    final dynamic message;
    final DateTime time;
    final Object? error;
    final StackTrace stackTrace;

    NokulogEvent(
        this.eventType, 
        this.message, {
        DateTime? time, 
        this.error, 
        StackTrace? stackTrace
    }) : time = time ?? DateTime.now(), stackTrace = stackTrace ?? StackTrace.current;

}

typedef NokulogCallback = void Function(NokulogEvent event); 

class Nokulog {
    static NokulogMode mode = NokulogMode.base; 

    static final List<NokulogEvent> log = [];

    static final Logger _logger = Logger(
        filter: ErrorFilter(),
        printer: PrettyPrinter()
    );
    static final HashSet<NokulogCallback> _callbacks = HashSet<NokulogCallback>();

    static void onEvent(NokulogCallback callback) {
        _callbacks.add(callback);
    }

    static void d(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
        _logger.d(message, time: time, error: error, stackTrace: stackTrace);

        if (mode == NokulogMode.errors || mode == NokulogMode.off) return;

        _addAndNotify(
            NokulogEvent(
                NokulogEventType.debug,
                message,
                time: time,
                error: error,
                stackTrace: stackTrace
            )
        );
    }

    static void i(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
        _logger.i(message, time: time, error: error, stackTrace: stackTrace);

        if (mode == NokulogMode.errors || mode == NokulogMode.off) return;

        _addAndNotify(
            NokulogEvent(
                NokulogEventType.info,
                message,
                time: time,
                error: error,
                stackTrace: stackTrace
            )
        );
    }

    static void w(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
        _logger.w(message, time: time, error: error, stackTrace: stackTrace);

        if (mode == NokulogMode.off) return;

        _addAndNotify(
            NokulogEvent(
                NokulogEventType.warning,
                message,
                time: time,
                error: error,
                stackTrace: stackTrace
            )
        );
    }

    static void e(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
        _logger.e(message, time: time, error: error, stackTrace: stackTrace);

        if (mode == NokulogMode.off) return;

        _addAndNotify(
            NokulogEvent(
                NokulogEventType.error,
                message,
                time: time,
                error: error,
                stackTrace: stackTrace
            )
        );
    }

    static void t(dynamic message, {DateTime? time, Object? error, StackTrace? stackTrace}) {
        _logger.t(message, time: time, error: error, stackTrace: stackTrace);

        if (mode == NokulogMode.off) return;
        
        _addAndNotify(
            NokulogEvent(
                NokulogEventType.trace,
                message,
                time: time,
                error: error,
                stackTrace: stackTrace
            )
        );
    }

    static void _addAndNotify(NokulogEvent event) {
        log.add(event);

        for (final callback in _callbacks) {
            callback(event);
        }
    }
}

class Dimensions {
    final int x;
    final int y;
    final Dimensions? alt;

    Dimensions(this.x, this.y, {this.alt});

    factory Dimensions.fromList(List<int> dimensions) {
        return Dimensions(dimensions[0], dimensions[1]);
    }

    factory Dimensions.fromMap(Map<String, dynamic> dimensions) {
        return Dimensions(
            dimensions["x"] as int,
            dimensions["y"] as int,
            alt: (dimensions["alt"] == null) ? null : Dimensions.fromMap(dimensions["alt"])
        );
    }

    Map<String, dynamic> toMap() => {
        "x": x,
        "y": y,
        "alt": alt?.toMap()
    };

    Map<String, dynamic> toJson() => {
        "x": x,
        "y": y,
        "alt": alt?.toMap()
    };

    @override
    String toString() {
        return "${x}x$y";
    }

    double get ratio => x / y;
}

String mapToPairedString(Map<dynamic, dynamic> map, {String separator = '&', String unifier = '='}) {
    final List<String> pairs = [];

    map.forEach((key, value) {
        pairs.add("$key$unifier$value");
    });

    return pairs.join(separator);
}

Map<String, String> pairedStringToMap(String str, {String separator = '&', String unifier = '='}) {
    final Map<String, String> pairs = {};

    str.split(separator).forEach((element) {
        final elementSplit = element.split(unifier);

        if (elementSplit.length < 2) return;

        pairs[elementSplit[0]] = elementSplit[1]; 
    });

    return pairs;
}

List<String> parseTags(String tags) {
    String currentText = "";
    final List<String> tagList = [];
    int numOfParenthesis = 0;

    for (int index = 0; index < tags.length; index++) {
        final char = tags[index];
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

List<String> parseTagsWithQuotes(String tags, {bool includeQuotes = false}) {
    String currentText = "";
    final List<String> tagList = [];
    bool inQuotations = false;

    for (int index = 0; index < tags.length; index++) {
        final char = tags[index];
        if (char == " " && !inQuotations) {
            tagList.add(currentText);
            currentText = "";
            continue;
        }

        if (char == '"') {
            inQuotations = !inQuotations;
            if (!includeQuotes) continue;
        }

        currentText += char;
    }

    if (currentText.isNotEmpty) {
        tagList.add(currentText);
    }

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

    for (final String char in chars.characters) {
        if (!chars.contains(char)) break;
        start += 1;
    }

    return text.substring(start - 1);
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
    final imageMD5 = md5.convert(imageData);

    return imageMD5.toString();
}

String toTitle(String string) {
    return string.substring(0, 1).toUpperCase() + string.substring(1);
}

var evaluator = DefaultRetryEvaluator({
    status408RequestTimeout,
    status500InternalServerError,
    status502BadGateway,
    status503ServiceUnavailable,
    status504GatewayTimeout,
    status440LoginTimeout,
    status460ClientClosedRequest,
    status499ClientClosedRequest,
    status520WebServerReturnedUnknownError,
    status521WebServerIsDown,
    status522ConnectionTimedOut,
    status523OriginIsUnreachable,
    status524TimeoutOccurred,
    status525SSLHandshakeFailed,
    status527RailgunError,
    status598NetworkReadTimeoutError,
    status599NetworkConnectTimeoutError
});

void addSmartRetry(Dio dio) {
    dio.interceptors.add(
        RetryInterceptor(
            dio: dio,
            logPrint: Nokulog.e,
            retries: 5,
            retryDelays: [
                const Duration(seconds: 1),
                const Duration(seconds: 2),
                const Duration(seconds: 5),
                const Duration(seconds: 30),
                const Duration(seconds: 60),
            ],
            retryEvaluator: (error, attempt) async {
                if (error.response?.statusCode == 429) {
                    if (attempt > 1) return false;

                    await Future.delayed(const Duration(minutes: 1));
                    return true;
                }

                if (error.response?.statusCode == 503 || error.response?.statusCode == 404 || error.response?.statusCode == 403) {
                    return false;
                }

                return evaluator.evaluate(error, attempt);
            },
        )
    );
}