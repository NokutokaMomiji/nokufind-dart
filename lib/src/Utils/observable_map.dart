import 'dart:collection';

/// Type alias for the callback function that receives the [map]
typedef MapChangedCallback<K, V> = void Function(ObservableMap<K, V> map);

/// An ObservableMap that notifies registered listeners on modifications.
class ObservableMap<K, V> extends MapBase<K, V> {
    final Map<K, V> _internal;
    final List<MapChangedCallback<K, V>> _listeners;

    /// Creates an ObservableMap, optionally initializing it with [initial].
    ObservableMap([Map<K, V>? initial]) : _internal = initial ?? {}, _listeners = [];

    /// Registers a callback to be called whenever the map is modified.
    void addListener(MapChangedCallback<K, V> callback) {
        _listeners.add(callback);
    }

    /// Unregisters a previously registered callback.
    void removeListener(MapChangedCallback<K, V> callback) {
        _listeners.remove(callback);
    }

    /// Notifies all registered listeners of a change.
    void _notifyListeners() {
        for (final listener in _listeners) {
            listener(this);
        }
    }

    // --- MapBase Implementation ---

    @override
    V? operator [](Object? key) => _internal[key];

    @override
    void operator []=(K key, V value) {
        _internal[key] = value;
        _notifyListeners();
    }

    @override
    void clear() {
        _internal.clear();
        _notifyListeners();
    }

    @override
    Iterable<K> get keys => _internal.keys;

    @override
    V? remove(Object? key) {
        final V? removed = _internal.remove(key);
        _notifyListeners();
        return removed;
    }
}
