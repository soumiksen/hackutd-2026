import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import 'api_error.dart';
import 'config.dart';

/// One method per contract endpoint (frontend-plan section 4). Every request sends X-User-Id.
class ApiClient {
  final Dio _dio;
  final String baseUrl;

  /// Called when the server rejects a signed-in session (expired or revoked), so the app can ask to sign in again.
  void Function()? onUnauthorized;

  ApiClient(String userId, {String? baseUrl, String? token})
      : baseUrl = baseUrl ?? Config.apiBaseUrl,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? Config.apiBaseUrl,
          headers: {'X-User-Id': userId, if (token != null) 'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 60),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(onError: (e, handler) {
      final hadToken = _dio.options.headers.containsKey('Authorization');
      if (hadToken && e.response?.statusCode == 401) onUnauthorized?.call();
      handler.next(e);
    }));
  }

  /// Signed-in sessions send `Authorization: Bearer <token>` (contract section 2). Null = anonymous device.
  void setToken(String? token) {
    if (token == null) {
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  /// Proof images: API_BASE_URL + proof.screenshot_urls[i] (endpoint 21).
  String proofUrl(String path) => '$baseUrl$path';

  Future<T> _call<T>(Future<Response> Function() req, T Function(dynamic data) parse) async {
    try {
      final r = await req();
      return parse(r.data);
    } on DioException catch (e) {
      throw ApiError.fromDio(e);
    }
  }

  Future<MultipartFile> _photo(XFile f) async =>
      MultipartFile.fromBytes(await f.readAsBytes(), filename: f.name.isEmpty ? 'photo.jpg' : f.name);

  // 1
  Future<bool> health() => _call(() => _dio.get('/health'), (d) => d['status'] == 'ok');
  // 2
  Future<User> upsertUser(User u) => _call(() => _dio.post('/users', data: u.toJson()), (d) => User.fromJson(d));
  // 23, 24, 25. The device's X-User-Id rides along on sign-up, so an anonymous profile keeps its cars.
  Future<AuthResult> signUp({
    required String email,
    required String password,
    required String name,
    required String phone,
    required bool consentRegister,
    required NotifyChannel notifyChannel,
  }) =>
      _call(
          () => _dio.post('/auth/signup', data: {
                'email': email,
                'password': password,
                'name': name,
                'phone': phone,
                'consent_register': consentRegister,
                'notify_channel': notifyChannel.name,
              }),
          (d) => AuthResult.fromJson(d));
  Future<AuthResult> signIn(String email, String password) => _call(
      () => _dio.post('/auth/signin', data: {'email': email, 'password': password}), (d) => AuthResult.fromJson(d));
  Future<void> signOut() => _call(() => _dio.post('/auth/signout'), (_) {});
  // 3
  Future<User> getMe() => _call(() => _dio.get('/users/me'), (d) => User.fromJson(d));
  // 4
  Future<VehicleVision> analyzeVehiclePhoto(XFile photo) async {
    final form = FormData.fromMap({'photo': await _photo(photo)});
    return _call(() => _dio.post('/vehicles/vision', data: form), (d) => VehicleVision.fromJson(d));
  }

  // 5
  Future<Vehicle> createVehicle(Vehicle v) =>
      _call(() => _dio.post('/vehicles', data: v.toJson()), (d) => Vehicle.fromJson(d));
  // 6
  Future<List<Vehicle>> listVehicles() =>
      _call(() => _dio.get('/vehicles'), (d) => [for (final v in d['vehicles']) Vehicle.fromJson(v)]);
  // 7
  Future<List<Property>> nearbyProperties(double lat, double lng, {int limit = 5}) => _call(
      () => _dio.get('/properties', queryParameters: {'lat': lat, 'lng': lng, 'limit': limit}),
      (d) => [for (final p in d['properties']) Property.fromJson(p)]);
  // 8
  Future<Property> getProperty(String propertyId) =>
      _call(() => _dio.get('/properties/$propertyId'), (d) => Property.fromJson(d));
  // 9
  Future<Registration> createDraft({
    required String vehicleId,
    required String propertyId,
    required Role role,
    Host? host,
    required int durationHours,
  }) =>
      _call(
          () => _dio.post('/registrations/draft', data: {
                'vehicle_id': vehicleId,
                'property_id': propertyId,
                'role': role.name,
                if (host != null) 'host': host.toJson(),
                'duration_hours': durationHours,
              }),
          (d) => Registration.fromJson(d));
  // 10
  Future<Registration> patchRegistration(String registrationId, Map<String, dynamic> patch) =>
      _call(() => _dio.patch('/registrations/$registrationId', data: patch), (d) => Registration.fromJson(d));
  // 11
  Future<Registration> confirmRegistration(String registrationId) => _call(
      () => _dio.post('/registrations/$registrationId/confirm', data: {'channel': 'app'}),
      (d) => Registration.fromJson(d));
  // 12
  Future<Registration> cancelRegistration(String registrationId) =>
      _call(() => _dio.post('/registrations/$registrationId/cancel'), (d) => Registration.fromJson(d));
  // 13
  Future<Registration> getRegistration(String registrationId) =>
      _call(() => _dio.get('/registrations/$registrationId'), (d) => Registration.fromJson(d));
  // 14
  Future<Registration> answerRegistration(String registrationId, String field, String value) => _call(
      () => _dio.post('/registrations/$registrationId/answer', data: {'field': field, 'value': value}),
      (d) => Registration.fromJson(d));
  // 15
  Future<Registration> resumeRegistration(String registrationId) =>
      _call(() => _dio.post('/registrations/$registrationId/resume'), (d) => Registration.fromJson(d));
  // 16
  Future<Registration> renewRegistration(String registrationId, int durationHours) => _call(
      () => _dio.post('/registrations/$registrationId/renew', data: {'duration_hours': durationHours}),
      (d) => Registration.fromJson(d));
  // 22: Maverick Place. The user already said yes to "park here?", so this starts at once. With no saved unit it
  // returns a registration that asks for the resident's phone (needs_user, field resident_phone).
  Future<Registration> maverickRegister({required String vehicleId, String? unit, String? residentLastName}) => _call(
      () => _dio.post('/maverick-place/register', data: {
            'vehicle_id': vehicleId,
            'confirm': true,
            'unit': ?unit,
            'resident_last_name': ?residentLastName,
          }),
      (d) => Registration.fromJson(d));
  // 17
  Future<List<Registration>> listPasses() =>
      _call(() => _dio.get('/passes'), (d) => [for (final r in d['passes']) Registration.fromJson(r)]);
}
