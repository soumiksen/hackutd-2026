import 'package:dio/dio.dart';

/// Parsed `{"error":{"code","message"}}` body (contract section 2).
class ApiError implements Exception {
  final String code;
  final String message;
  final int? status;
  const ApiError(this.code, this.message, [this.status]);

  factory ApiError.fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return ApiError('${err['code'] ?? 'error'}', '${err['message'] ?? 'Something went wrong.'}',
          e.response?.statusCode);
    }
    if (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.connectionTimeout) {
      return const ApiError('offline', "Can't reach the Parkour server. Check your connection and try again.");
    }
    return ApiError('error', 'Something went wrong (${e.response?.statusCode ?? e.type.name}).',
        e.response?.statusCode);
  }

  @override
  String toString() => message;
}
