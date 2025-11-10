import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:dio/dio.dart";

enum APIErrorType {
    network,
    timeout,
    server,
    client,
    parsing,
    cancelled,
    notFound,
    forbidden,
    unknown
}

class APIError {
    final APIErrorType type;
    final String message;
    final String? url;
    final Exception? exception;
    final StackTrace? stackTrace;

    APIError({required this.type, required this.message, this.url, this.exception, this.stackTrace});
}

class APIResult<T> {
    final T? data;
    final APIError? error;
    final int? statusCode;

    APIResult.success(this.data, {this.statusCode}) : error = null;
    APIResult.failed(this.error, {this.statusCode}) : data = null;

    bool get isSuccess => data != null && error == null;
    bool get isError => error != null;
}

/// Base class that defines functions that allow you to request and transform data from APIs.
/// 
/// Class defines a [safeGET] and [safeGETRaw] functions for making requests and transforming them.
/// All requests are wrapped in an [APIResult]. Request data can be accessed via [APIResult.data]
/// 
/// If an error ocurred, either due to an issue with the request or parsing, the result will contain
/// an [APIError] with a specified [APIErrorType] as well as other data regarding the issue.
/// 
/// Any errors that occur whilst making and handling a request can be listened for via the [errors] stream.
/// 
/// This class is not meant to be directly used, but be expanded.
abstract class BaseAPI {
    final Dio client;
    final Duration timeout;

    final StreamController<APIError> _errorStreamController = StreamController.broadcast();

    BaseAPI(this.client, {this.timeout = const Duration(seconds: 15)}) {
        client.options.connectTimeout = timeout;
        client.options.receiveTimeout = timeout;
    }

    Future<APIResult<T>> safeGET<T>(
        String url, 
        T Function(String rawData) converter, {
            Map<String, dynamic>? queryParameters,
            Options? options,
            CancelToken? cancelToken   
        }
    ) async {
        try {
            final response = await client.get<String>(
                url,
                queryParameters: queryParameters,
                options: options,
                cancelToken: cancelToken
            );

            return _handleResponse(response, converter);
        } on DioException catch (e, stackTrace) {
            return _convertDioError<T>(e, stackTrace);
        } catch (e, stackTrace) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.unknown,
                    message: "Unexpected error on GET",
                    exception: (e is Exception) ? e : Exception(e.toString()),
                    stackTrace: stackTrace
                )
            );
        }
    }

    Future<APIResult<T>> safeGETRaw<T>(
        String url, 
        T Function(Uint8List rawData) converter, {
            Map<String, dynamic>? queryParameters,
            Options? options,
            CancelToken? cancelToken   
        }
    ) async {
        try {
            options?.responseType = ResponseType.bytes;

            final response = await client.get<Uint8List>(
                url,
                queryParameters: queryParameters,
                options: options,
                cancelToken: cancelToken
            );

            return _handleResponseRaw(response, converter);
        } on DioException catch (e, stackTrace) {
            return _convertDioError<T>(e, stackTrace);
        } catch (e, stackTrace) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.unknown,
                    message: "Unexpected error on GET",
                    exception: (e is Exception) ? e : Exception(e.toString()),
                    stackTrace: stackTrace
                )
            );
        }
    }

    APIResult<T> _buildFailure<T>(APIError error, {int? statusCode}) {
        _errorStreamController.sink.add(error);

        return APIResult.failed(error, statusCode: statusCode);
    }

    APIResult<T> _handleResponse<T>(Response response, T Function(String) converter) {
        final code = response.statusCode;

        if (code == null) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.unknown,
                    message: "Status code unknown.",
                    url: response.requestOptions.path,
                )
            );
        }

        if (code == 404) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.notFound, 
                    message: "Resourse Not Found (404)",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        if (code == 403) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.forbidden,
                    message: "Forbidden (403)",
                    url: response.requestOptions.path,
                ),
                statusCode: code
            );
        }

        // Request was successful, so we try parsing the response.
        if (code >= 200 && code < 300) {
            try {
                final result = converter(response.data as String);
                
                return APIResult.success(
                    result, 
                    statusCode: code
                );
            } catch (e, stackTrace) {
                return _buildFailure(APIError(
                        type: APIErrorType.parsing,
                        message: "Parsing failed: $e",
                        url: response.requestOptions.path,
                        exception: (e is Exception) ? e : Exception(e.toString()),
                        stackTrace: stackTrace
                    ), 
                    statusCode: code
                );
            }
        }

        if (code >= 400 && code < 500) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.client,
                    message: "Client error: $code",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        if (code >= 500 && code < 600) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.server,
                    message: "Server error: $code",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        return _buildFailure(
            APIError(
                type: APIErrorType.unknown,
                message: "Unhandled status code: $code",
                url: response.requestOptions.path,
            ), 
            statusCode: code
        );
    }

    APIResult<T> _handleResponseRaw<T>(Response response, T Function(Uint8List) converter) {
        final code = response.statusCode;

        if (code == null) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.unknown,
                    message: "Status code unknown.",
                    url: response.requestOptions.path,
                )
            );
        }

        if (code == 404) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.notFound, 
                    message: "Resourse Not Found (404)",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        if (code == 403) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.forbidden,
                    message: "Forbidden (403)",
                    url: response.requestOptions.path,
                ),
                statusCode: code
            );
        }

        // Request was successful, so we try parsing the response.
        if (code >= 200 && code < 300) {
            try {
                final result = converter(response.data);
                
                return APIResult.success(
                    result, 
                    statusCode: code
                );
            } catch (e, stackTrace) {
                return _buildFailure(APIError(
                        type: APIErrorType.parsing,
                        message: "Parsing failed: $e",
                        url: response.requestOptions.path,
                        exception: (e is Exception) ? e : Exception(e.toString()),
                        stackTrace: stackTrace
                    ), 
                    statusCode: code
                );
            }
        }

        if (code >= 400 && code < 500) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.client,
                    message: "Client error: $code",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        if (code >= 500 && code < 600) {
            return _buildFailure(
                APIError(
                    type: APIErrorType.server,
                    message: "Server error: $code",
                    url: response.requestOptions.path,
                ), 
                statusCode: code
            );
        }

        return _buildFailure(
            APIError(
                type: APIErrorType.unknown,
                message: "Unhandled status code: $code",
                url: response.requestOptions.path,
            ), 
            statusCode: code
        );
    }

    APIResult<T> _convertDioError<T>(DioException dioError, StackTrace stackTrace) {
        APIErrorType type;

        switch (dioError.type) {
            case DioExceptionType.connectionTimeout:
            case DioExceptionType.sendTimeout:
            case DioExceptionType.receiveTimeout:
                type = APIErrorType.timeout;
                break;

            case DioExceptionType.badResponse:
                final status = dioError.response?.statusCode;
                
                if (status == 403) {
                    type = APIErrorType.forbidden;
                    break;
                }
                
                if (status == 404) {
                    type = APIErrorType.notFound;
                    break;
                } 
                
                if (status != null && status >= 500) {
                    type = APIErrorType.server;
                    break;
                } 
                
                if (status != null && status >= 400) {
                    type = APIErrorType.client;
                    break;
                }

                type = APIErrorType.unknown;
                break;

            case DioExceptionType.cancel:
                type = APIErrorType.cancelled;
                break;

            case DioExceptionType.unknown:
            default:
                type = APIErrorType.network;
        }

        return _buildFailure(
            APIError(
                type: type,
                message: dioError.message ?? "Unknown Dio error.",
                url: dioError.requestOptions.path,
                exception: dioError,
                stackTrace: stackTrace
            ), 
            statusCode: dioError.response?.statusCode
        );
    }

    Stream<APIError> get errors => _errorStreamController.stream;
}