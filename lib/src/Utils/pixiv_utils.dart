import 'dart:collection';

class PixivError implements Exception {
    final String reason;
    final Map<String, dynamic>? header;
    final String? body;

    PixivError(this.reason, {this.header, this.body});

    @override
    String toString() => reason;
}

class CaseInsensitiveMap<T> extends MapBase<String, T> {
    final Map<String, T> _map = {};

    CaseInsensitiveMap([Map<String, T>? other]) {
        if (other == null) return;

        other.forEach((key, value) {
            _map[key.toLowerCase()] = value;
        });
    }

    @override
    T? operator [](Object? key) {
        if (key is String) {
            return _map[key.toLowerCase()];
        }

        return null;
    }

    @override
    void operator []=(String key, T value) {
        _map[key.toLowerCase()] = value;
    }

    @override
    void clear() {
        _map.clear();
    }

    @override
    Iterable<String> get keys => _map.keys;

    @override
    T? remove(Object? key) {
        if (key is String) {
            return _map.remove(key.toLowerCase());
        }

        return null;
    }
} 