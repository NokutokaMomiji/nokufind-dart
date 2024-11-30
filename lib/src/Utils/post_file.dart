import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:nokufind/src/Utils/utils.dart';

class PostFileStatus {
    final int contentLength;
    final int currentLength;
    final Uint8List? data;

    const PostFileStatus(this.contentLength, this.currentLength, this.data);
}

class PostFile {
    final String url;
    final String filename;
    Map<String, String> headers;
    final Dio client;
    final Dio fallbackClient;
    final StreamController<PostFileStatus> _controller = StreamController<PostFileStatus>.broadcast();

    Uint8List _data = Uint8List(0);
    CancelToken? _cancelToken;
    Completer _completer = Completer();

    int _contentLength = 0;
    int _currentLength = 0;

    bool _isFetching = false;
    bool _inStream = false;
    bool _completed = false;

    PostFile({
        required this.url, 
        required this.filename, 
        required this.headers, 
        required this.client, 
        required this.fallbackClient
    });

    Future<Uint8List?> fetch({bool asStream = false}) async {
        // In case that the fetching is already in progress, we want to avoid making more network requests.
        // So we just wait until the current request is done and we return whatever data was received.
        if (_isFetching) {
            await _completer.future;
            return data;
        }

        if (_completed) return data;

        _isFetching = true;
        _completer = (_completer.isCompleted) ? Completer() : _completer;
        _cancelToken = CancelToken();

        if (asStream) {
            return _fetchAsStream();
        }

        return _fetch();
    }

    void cancel([Object? reason]) {
        _cancelToken?.cancel(reason);
    }

    void clear() {
        // If we are still fetching the data, we cancel the fetch since we're going to clear the data anyway.
        if (_cancelToken != null) cancel("Post data clear has been requested.");

        // We reset all variables back to their default state.
        _cancelToken = null;
        _data = Uint8List(0);
        _contentLength = 0;
        _currentLength = 0;
        _isFetching = false;
        _completed = false;
        _inStream = false;
    }

    Future<Uint8List?> _fetch() async {
        _inStream = false;

        var response = await _getResponseAsBytes();

        // If the response was null, either the request failed or it was cancelled.
        if (response == null) {
            _completeFetch(failed: true);
            return null;
        }

        _data = response.data ?? _data;

        _completeFetch(failed: (response.data != null));
        return response.data;
    }

    Future<Uint8List?> _fetchAsStream() async {
        _inStream = true;

        var response = await _getResponseAsBody();

        // If the response was null, either the request failed or it was cancelled.
        if (response == null) {
            _completeFetch(failed: true);
            return null;
        }

        // Since the response type is a stream, we have to manually listen and fetch the byte data from the stream.
        BytesBuilder totalData = BytesBuilder();

        try {
            await for (var data in response.data!.stream) {
                if (_controller.hasListener) {
                    _controller.sink.add(
                        PostFileStatus(
                            _contentLength, 
                            _currentLength, 
                            data
                        )
                    );
                }

                totalData.add(data);
            }

            _data = totalData.toBytes();
            _completeFetch();
            return _data;
        } catch (e, stackTrace) {
            if (_requestWasCancelled(e)) {
                Nokulog.w("Request was cancelled by user.", error: e, stackTrace: stackTrace);
                _completeFetch(failed: true);
                return null;
            }

            String expectedData = "Bytes expected: ${(_contentLength == 0) ? 'unknown' : _contentLength}. Bytes received: ${totalData.length}";
            Nokulog.e("Request for file \"$url\" failed. ($expectedData)", error: e, stackTrace: stackTrace);
            _completeFetch(failed: true);
            return null;
        }
    }

    Future<Response<Uint8List>?> _getResponseAsBytes() async {
        // We configure the headers and configure the response type to bytes.
        Options options = Options(
            responseType: ResponseType.bytes,
            headers: headers
        );

        // First we try the normal client.
        try {
            return await client.get<Uint8List>(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: _fetchCallback
            );
        } catch (e, stackTrace) {
            if (_requestWasCancelled(e)) {
                Nokulog.w("Request was cancelled by user.", error: e, stackTrace: stackTrace);
                return null;
            }

            if (e is DioException) {
                Nokulog.w("Request failed. Trying fallback client. ${e.message}");
                if (e.response != null) {
                    String? possibleWaitTime = e.response!.headers.value("Retry-After");
                    if (possibleWaitTime != null) {
                        int waitTime = int.tryParse(possibleWaitTime) ?? 30;
                        Nokulog.w("Wait time has been set to: $waitTime");
                        if (waitTime >= 3600) {
                            return null;
                        }
                        
                        await Future.delayed(Duration(seconds: waitTime));
                    }
                }
            } else {
                Nokulog.w("Request failed. Trying fallback client.", error: e, stackTrace: stackTrace);
            }
        }
    
        // If we reached here, the main client failed so we try the fallback client.
        try {
            return await fallbackClient.get<Uint8List>(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: _fetchCallback
            );
        } catch (e, stackTrace) {
            if (_requestWasCancelled(e)) {
                Nokulog.w("Request was cancelled by user.", error: e, stackTrace: stackTrace);
                return null;
            }

            String possibleMessage = (e is DioException) ? " ${e.message}" : "";
            Nokulog.e("Request for file \"$url\" failed.$possibleMessage", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<Response<ResponseBody>?> _getResponseAsBody() async {
        Options options = Options(
            responseType: ResponseType.stream,
            headers: headers
        );

        try {
            return await client.get(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: _fetchCallback
            );
        } catch (e, stackTrace) {
            if (_requestWasCancelled(e)) {
                Nokulog.w("Request was cancelled by user.", error: e, stackTrace: stackTrace);
                return null;
            }

            if (e is DioException) {
                Nokulog.w("Request failed. Trying fallback client. ${e.message}");
                if (e.response != null) {
                    String? possibleWaitTime = e.response!.headers.value("Retry-After");
                    if (possibleWaitTime != null) {
                        int waitTime = int.tryParse(possibleWaitTime) ?? 30;
                        Nokulog.w("Wait time has been set to: $waitTime");
                        if (waitTime >= 3600) {
                            return null;
                        }
                        
                        await Future.delayed(Duration(seconds: waitTime));
                    }
                }
            } else {
                Nokulog.w("Request failed. Trying fallback client.", error: e, stackTrace: stackTrace);
            }
        }
    
        try {
            return await fallbackClient.get(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: _fetchCallback
            );
        } catch (e, stackTrace) {
            if (_requestWasCancelled(e)) {
                Nokulog.w("Request was cancelled by user.", error: e, stackTrace: stackTrace);
                return null;
            }

            String possibleMessage = (e is DioException) ? " ${e.message}" : "";
            Nokulog.e("Request for file \"$url\" failed.$possibleMessage", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    bool _requestWasCancelled(Object e) {
        return (e is DioException && CancelToken.isCancel(e));
    }

    void _fetchCallback(int count, int total) {
        if (total != -1) {
            _contentLength = total;
        }

        _currentLength = count;

        if (!_inStream && _controller.hasListener) {
            _controller.sink.add(
                PostFileStatus(
                    total, 
                    count,
                    null
                )
            );
        }
    }

    void _completeFetch({bool failed = false}) {
        _isFetching = false;
        _completed = !failed;
        if (!_completer.isCompleted) _completer.complete();
    }

    /// A broadcast stream that broadcasts ``PostFileStatus`` objects while the data is being fetched.
    /// 
    /// If the fetch was started with ``asStream`` set to ``true``, the ``data`` variable will be filled
    /// with the most recent chunk of data.
    Stream<PostFileStatus> get stream => _controller.stream;

    /// The byte data from the file.
    /// 
    /// If the data has not been fetched, has been cleared, or the fetch failed or was cancelled, the result will be ``null``.
    Uint8List? get data => (_data.isEmpty) ? null : _data;

    /// Returns the expected length of the data to receive.
    /// 
    /// If the data fetch has been completed, this is the same as the length of the data list.
    int get contentLength => _contentLength;

    /// Returns the data that has been received at the moment.
    /// 
    /// If the data fetch has been completed successfully, the length will be the same as the data list.
    int get receivedLength => _currentLength;
    
    /// Returns the current fetch progress as a decimal value between zero and one.
    /// 
    /// This will be zero if no data has been received or if the content length is unknown.
    double get progress => (contentLength != 0) ? (receivedLength / contentLength) : 0;

    /// Returns the current fetch progress as a percentage.
    /// 
    /// This will be zero if no data has been received or if the content length is unknown.
    int get progressPercentage => (progress * 100).floor();
    
    /// Indicates whether the file data fetch was completed successfully.
    /// 
    /// If the fetch failed, this will be ``false``.
    bool get completed => _completed;

    /// Indicates whether the file fetch is currently in progress.
    bool get inProgress => _isFetching;
}