import 'dart:async';

import 'package:async/async.dart';
import 'package:executor/executor.dart';
import '../post.dart';

/// A simple enum that marks the status of either the global download status as well as the download of a single post.
enum DownloadStatus {
    started,
    finished,
    downloadStart,
    downloadEnd,
    downloadFailed,
    cancelled
}

/// Class that contains the current [DownloadStatus] of a post, as well as relevant data such as the [Post] 
/// and an [Exception] if one occurs.
/// 
/// This class is used by [DownloadStream] and is not meant to be created manually.
class DownloadData {
    final Post? _post;
    final DownloadStatus _status;
    final Exception? _error;

    DownloadData(this._post, this._status, [this._error]);

    Post? get post => _post;
    DownloadStatus get status => _status;
    Exception? get error => _error;
}

/// A class that allows for fetching [Post] data as a [Stream], which sends [DownloadData] objects containing
/// the current [DownloadStatus] for a post and relevant download information.
/// 
/// You can supply a [FutureOr] callback that will be called with the post once its data has been fetched.
/// 
/// (Do keep in mind that the function will be called regardless of any null data that may be stored inside, 
/// so it is up to you to make sure that the inner data is valid.)
/// 
/// You can also use [cancel] to cancel the fetching.
class DownloadStream {
    static const String _defaultTitle = "Download Stream";

    final StreamController<DownloadData> _controller = StreamController<DownloadData>();
    final Executor _executor = Executor(concurrency: 15);
    late List<Post> _postList;
    final List<CancelableOperation> _tasks = [];

    late Stream<DownloadData> _stream;
    int _completed = 0;
    String _title = _defaultTitle;
    bool _hasCancelled = false;
    FutureOr<void> Function()? onFinished;

    DownloadStream(postList) {
        _stream = _controller.stream.asBroadcastStream();
        _postList = List<Post>.from(postList);

        if (_postList.isEmpty) {
            cancel();
            return;
        }

        _controller.onCancel = cancel;
        _stream = _controller.stream.asBroadcastStream();
    }
    
    Future<void> start(FutureOr<void> Function(Post post)? onFetched, {FutureOr<void> Function()? onFinished}) async {
        // We indicate that the process has started.
        _controller.sink.add(DownloadData(null, DownloadStatus.started));

        this.onFinished = onFinished;

        // We iterate through each post and fetch the data.
        for (Post post in _postList) {
            // We save the download task future to be able to add the onError callback as well as make it cancellable.
            Future downloadTask = _executor.scheduleTask(() async {
                DownloadStream instance = this;

                if (instance._hasCancelled) return;

                // We indicate that the download has started.
                _controller.sink.add(DownloadData(post, DownloadStatus.downloadStart));
                
                // This fetches all the data from the post and stores it internally.
                Future fetchFuture = post.fetchData();

                if (instance._hasCancelled) return;

                // Once the post fetch process has finished, we want to indicate that it finished downloading.
                fetchFuture.then(
                    (value) => _controller.add(DownloadData(post, DownloadStatus.downloadEnd))
                );

                // Whether the post fetch fails or not, we want to register that we have gone through this post.
                fetchFuture.whenComplete(() => _completed++);

                // Now, we simply wait for the future to be done.
                await fetchFuture;

                // If we have registered a callback, call it with the post so that the user may do what they wish. (i.e. Store the data.)
                if (onFetched != null) {
                    onFetched(post);
                }
            });

            downloadTask.onError<Exception>(
                (error, stackTrace) => DownloadData(post, DownloadStatus.downloadFailed, error)
            );
            
            _tasks.add(
                CancelableOperation.fromFuture(downloadTask, onCancel: () {
                    post.cancelFetch();
                })
            );
        }

        await _executor.join(withWaiting: true);
        await _executor.close();

        // After everything, the process is done, so we indicate that we have finished.
        _controller.sink.add(DownloadData(null, DownloadStatus.finished));
        
        var finishedFunc = this.onFinished;
        if (finishedFunc != null) {
            finishedFunc();
        }
    }

    Future<void> cancel() async {
        _controller.sink.add(DownloadData(null, DownloadStatus.cancelled));

        _hasCancelled = true;

        for (var task in _tasks) {
            task.cancel();
        }

        await _executor.close();

        var finishedFunc = onFinished;
        if (finishedFunc != null) {
            finishedFunc();
        }
    }

    String get title => _title;
    set title(String value) {
        _title = (value.isEmpty) ? _defaultTitle : value;
    }

    int get completed => _completed;
    int get total => _postList.length;
    double get completedPercentage => (_postList.isNotEmpty) ? (_completed / _postList.length) * 100 : 0;
    Stream<DownloadData> get stream => _stream;
}