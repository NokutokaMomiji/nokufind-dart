import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:nokufind/src/Utils/utils.dart';

/// Class that contains the current length of the file data of a [StreamedFile], as well as the expected total length
/// and the last chunk of data that was received.
/// 
/// This class is used by [StreamedFile] and is not meant to be created manually.
class FileDownloadStatus {
    final int contentLength;
    final int currentLength;
    final Uint8List data;

    FileDownloadStatus(this.contentLength, this.currentLength, this.data);
}

/// A class that allows for fetching the data of an online file as a [Stream], which sends [FileDownloadStatus] objects
/// containing the last chunk received and the state of the download.
/// 
/// To begin the fetching process, use [fetchFile]. The [data] and [receivedLength] variables will be automatically updated
/// to their latest values, in case you wish not to use the stream.
/// 
/// You can also use [awaitData] to receive a [Future] that completes as soon as the data has been completely fetched.
/// 
/// Finally, you can use [cancel] to cancel the fetching, or use [clear] to remove the data from memory.
class StreamedFile {
    final String url;
    final String filename;
    Map<String, String> headers;
    final Dio client;
    final Dio fallbackClient;
    final StreamController<FileDownloadStatus> _controller = StreamController<FileDownloadStatus>.broadcast();

    Uint8List _data = Uint8List(0);
    Completer? _completer;
    CancelToken? _cancelToken;
    int _contentLength = 0;

    StreamedFile({
        required this.url, 
        required this.filename, 
        required this.headers, 
        required this.client, 
        required this.fallbackClient, 
        bool start = false
    }) {
        if (start) fetchFile();
    }

    Future<void> fetchFile() async {
        // If the completer is null, this means we are either already downloading the file, or we already finished the download.
        if (_completer != null) {
            // If the completer has been completed, but the data is null, we understand an error probably happened, so we continue.
            if (!(_completer?.isCompleted == true && data == null)) {
                return;
            }
        }

        // We reinitialize the variables with fresh objects.
        _cancelToken = CancelToken();
        _completer = Completer();

        // The file buffer will contain the data as we receive it. This will then be converted into a Uint8List.
        final List<int> fileBuffer = [];
        final Options options = Options(
            responseType: ResponseType.stream,
            headers: headers
        );

        // We try to get a response in both the default and fallback clients.
        Response<ResponseBody>? response = await _getResponse(options) ?? await _getFallbackResponse(options);

        // Both requests failed for some reason and we have no response, so we complete and leave.
        if (response == null) {
            _completer?.complete();
            return;
        }

        try {
            // We iterate through the chunks of data as we receive them.
            await for (var chunk in response.data!.stream) {
                // We add the chunk to the file buffer and convert it into a Uint8List.
                fileBuffer.addAll(chunk);
                _data = Uint8List.fromList(fileBuffer);

                // We send new status data to the stream for any listeners.
                _controller.add(
                    FileDownloadStatus(
                        contentLength, 
                        receivedLength, 
                        chunk
                    )
                );
            }

            // We have finished fetching the file without any issues, so we complete.
            _completer?.complete();
        } catch (e, stackTrace) {
            // This runs if the request was cancelled by the user.
            if (e is DioException && CancelToken.isCancel(e)) {
                Nokulog.w("Request for \"$url\" was cancelled.", error: e, stackTrace: stackTrace);
                _completer?.complete();
                return;
            }

            Nokulog.e("An error occurred whilst fetching \"$url\".", error: e, stackTrace: stackTrace);
            _completer?.complete();
            return;
        }
    }

    Future<Uint8List?> awaitData() async {
        // If the data isn't null, we can just return the data.
        if (data != null) return data;

        // If the completer is null, we're safe to just fetch the file.
        if (_completer == null) {
            await fetchFile();
        }

        // We wait until the process has either finished or failed to return whatever we have as data.
        await _completer!.future;
        return data;
    }

    /// Cancels the fetch. This also completes the [Future] given by [awaitData].
    void cancel([Object? reason]) {
        if (_completer == null) {
            Nokulog.w("An attempt has been made to cancel a StreamedFile that hasn't been started.");
            return;
        }

        CancelToken? cancelToken = _cancelToken;
        if (cancelToken == null) return;

        cancelToken.cancel(reason);

        if (_completer?.isCompleted == false) {
            _completer?.complete();
        }
    }

    void clear() {
        _completer = null;
        _cancelToken = null;
        _data = Uint8List(0);
        _contentLength = 0;
    }

    Future<Response<ResponseBody>?> _getResponse(Options options) async {
        try {
            return await client.get(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: (count, total) {
                    if (total != -1) {
                        _contentLength = total;
                    }
                }
            );
        } catch (e, stackTrace) {
            Nokulog.w("Request failed. Trying fallback client.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Future<Response<ResponseBody>?> _getFallbackResponse(Options options) async {
        try {
            return await fallbackClient.get(
                url,
                options: options,
                cancelToken: _cancelToken,
                onReceiveProgress: (count, total) {
                    if (total != -1) {
                        _contentLength = total;
                    }
                }
            );
        } catch (e, stackTrace) {
            Nokulog.e("Request for file \"$url\" failed.", error: e, stackTrace: stackTrace);
            return null;
        }
    }

    Stream<FileDownloadStatus> get stream => _controller.stream;
    Uint8List? get data => (_data.isEmpty) ? null : _data;
    int get contentLength => _contentLength;
    int get receivedLength => _data.length;
    double get progress => (_data.isNotEmpty) ? (receivedLength / contentLength) : 0;
    int get progressPercentage => (progress * 100).floor();
    bool get completed => (_completer?.isCompleted == true);
    bool get inProgress => (_completer != null && _completer?.isCompleted == false);
}