// Runs the app's real ApiClient against a running backend (default http://127.0.0.1:8000).
//   scripts/dev.sh &   then   flutter test test/auth_flow_test.dart
// Skipped automatically when the backend is not reachable.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parkour/core/api_client.dart';
import 'package:parkour/core/api_error.dart';
import 'package:parkour/models/models.dart';

const base = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8000');

Future<bool> backendUp() async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final r = await (await c.getUrl(Uri.parse('$base/health'))).close();
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('onboarding saves the user: sign up, add car, sign in from another device', () async {
    if (!await backendUp()) {
      markTestSkipped('backend not running at $base');
      return;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final email = 'flutter$stamp@example.com';

    // Device A: what onboarding does.
    final a = ApiClient('device-a-$stamp', baseUrl: base);
    final signup = await a.signUp(
      email: email,
      password: 'correct horse',
      name: 'Maya Lee',
      phone: '+15550100123',
      consentRegister: true,
      notifyChannel: NotifyChannel.both,
    );
    expect(signup.user.hasAccount, isTrue);
    expect(signup.user.email, email);
    expect(signup.user.notifyChannel, NotifyChannel.both);
    expect(signup.token, isNotEmpty);
    a.setToken(signup.token);
    final car = await a.createVehicle(
        const Vehicle(plate: 'ABC1234', state: 'TX', make: 'Honda', model: 'Civic', color: 'Blue'));
    expect(car.vehicleId, isNotNull);

    // Same email twice is refused with a clear code.
    final dup = ApiClient('device-x-$stamp', baseUrl: base);
    await expectLater(
      dup.signUp(
          email: email,
          password: 'another one 1',
          name: 'X',
          phone: '+15550100124',
          consentRegister: false,
          notifyChannel: NotifyChannel.app),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'conflict')),
    );

    // Device B: a fresh install signs in and gets the same profile and car back.
    final b = ApiClient('device-b-$stamp', baseUrl: base);
    await expectLater(
      b.signIn(email, 'wrong password!'),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'unauthorized')),
    );
    final signin = await b.signIn(email, 'correct horse');
    b.setToken(signin.token);
    expect(signin.user.name, 'Maya Lee');
    expect((await b.getMe()).phone, '+15550100123');
    final cars = await b.listVehicles();
    expect(cars.map((v) => v.plate), ['ABC1234']);
    expect(cars.first.vehicleId, car.vehicleId);

    // Signing out ends the session.
    var expired = false;
    b.onUnauthorized = () => expired = true;
    await b.signOut();
    await expectLater(b.getMe(), throwsA(isA<ApiError>()));
    expect(expired, isTrue);
  });
}
