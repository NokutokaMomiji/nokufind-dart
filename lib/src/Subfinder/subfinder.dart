import '../post.dart';
import '../comment.dart';
import '../note.dart';

class SubfinderConfiguration {
    Function(String, dynamic, bool, bool)? _callback;

    final Map<String, dynamic> _config = {};
    final Map<String, String> _headers = {};
    final Map<String, String> _cookies = {};
    bool _setProperties = false;

    SubfinderConfiguration({Function(String, dynamic, bool, bool)? callback}) {
        _callback = callback;
        
        _config["api_key"] = null;
        
        _headers["User-Agent"] = "";
        _headers["Referer"] = "";

        _cookies["cf_clearance"] = "";
    }

    void setCookie(String key, String value) {
        _cookies[key] = value;

        if (_callback != null) {
            _callback!(key, value, true, false);
        }
    }

    String getCookie(String key) {
        if (!_cookies.containsKey(key)) {
            throw ArgumentError.value(key, "key");
        }

        return _cookies[key] as String;
    }

    void setHeader(String key, String value) {
        _headers[key] = value;

        if (_callback != null) {
            _callback!(key, value, false, true);
        }
    }

    String getHeader(String key) {
        if (!_headers.containsKey(key)) {
            throw ArgumentError.value(key, "key");
        }

        return _headers[key] as String;
    }

    void setConfig(String key, dynamic value) {
        if (key == "headers" || key == "cookies" || !_config.containsKey(key)) {
            throw ArgumentError.value(key, "key", "No setting.");
        }

        _config[key] = value;

        _callback!(key, value, false, false);
    }

    T? getConfig<T>(String key, {T? defaultValue}) {
        if (!_config.containsKey(key)) {
            return defaultValue;
        }

        return _config[key];
    }

    void setProperty(String key, dynamic defaultValue) {
        if (_setProperties) {
            throw StateError("Do not use setProperty. Use setConfig, setHeaders or setCookies instead.");
        }

        if (key == "headers" || key == "cookies") {
            throw ArgumentError.value(key, "key", "Do not use setProperty for configuring headers or cookies. Use the respective functions.");
        }

        _config[key] = defaultValue;
    }

    void lockProperties() {
        _setProperties = true;
    }

    void setCallback(Function(String, dynamic, bool, bool)? callback) {
        _callback = callback;
    }
}

abstract interface class ISubfinder {
    final _config = SubfinderConfiguration();

    Future<List<Post>> searchPosts(String tags, {int limit = 100, int? page});
    Future<Post?> getPost(int postID);

    Future<List<Comment>> searchComments({int? postID, int limit = 100, int? page});
    Future<Comment?> getComment(int commentID, {int? postID});
    
    Future<List<Note>> getNotes(int postID);
    
    Future<Post?> postGetParent(Post post);
    Future<List<Post>> postGetChildren(Post post);

    SubfinderConfiguration get configuration {
        return _config;
    }
}