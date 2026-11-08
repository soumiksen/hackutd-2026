// Dart mirrors of the contract objects (API_CONTRACT.md section 4).
// Hand-written fromJson/toJson keep the snake_case field names exactly.

enum Role { resident, visitor }

enum NotifyChannel { app, message, both }

enum RegistrationStatus {
  drafted, awaitingConfirm, submitting, needsUser, confirmed, failed, cancelled, expired, finished;

  static RegistrationStatus parse(String s) => switch (s) {
        'drafted' => drafted,
        'awaiting_confirm' => awaitingConfirm,
        'submitting' => submitting,
        'needs_user' => needsUser,
        'confirmed' => confirmed,
        'failed' => failed,
        'cancelled' => cancelled,
        'expired' => expired,
        'finished' => finished,
        _ => drafted,
      };

  bool get isActive => this == submitting || this == awaitingConfirm || this == needsUser || this == drafted;
}

enum NeedsUserReason {
  captcha, missingInfo, ruleConflict, payment;

  static NeedsUserReason parse(String s) => switch (s) {
        'captcha' => captcha,
        'missing_info' => missingInfo,
        'rule_conflict' => ruleConflict,
        _ => payment,
      };
}

enum StepStatus {
  pending, running, done, error;

  static StepStatus parse(String s) =>
      StepStatus.values.firstWhere((v) => v.name == s, orElse: () => StepStatus.pending);
}

class User {
  final String name, phone, email;
  final bool consentRegister;
  final double spendingCapUsd;
  final NotifyChannel notifyChannel;
  const User({
    required this.name,
    required this.phone,
    required this.email,
    required this.consentRegister,
    this.spendingCapUsd = 10,
    this.notifyChannel = NotifyChannel.app,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        email: j['email'] ?? '',
        consentRegister: j['consent_register'] == true,
        spendingCapUsd: (j['spending_cap_usd'] as num?)?.toDouble() ?? 0,
        notifyChannel: NotifyChannel.values.firstWhere((c) => c.name == j['notify_channel'],
            orElse: () => NotifyChannel.app),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'phone': phone,
        'email': email,
        'consent_register': consentRegister,
        'spending_cap_usd': spendingCapUsd,
        'notify_channel': notifyChannel.name,
      };
}

class Vehicle {
  final String? vehicleId;
  final String plate, state, make, model, color;
  final int? year;
  const Vehicle({
    this.vehicleId,
    required this.plate,
    required this.state,
    required this.make,
    required this.model,
    required this.color,
    this.year,
  });

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
        vehicleId: j['vehicle_id'],
        plate: j['plate'] ?? '',
        state: j['state'] ?? '',
        make: j['make'] ?? '',
        model: j['model'] ?? '',
        color: j['color'] ?? '',
        year: (j['year'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'plate': plate,
        'state': state,
        'make': make,
        'model': model,
        'color': color,
        if (year != null) 'year': year,
      };

  String get label => '$color $make $model';
}

class GuestRules {
  final int maxNightsPerMonth, maxDurationHours;
  final bool requiresHostUnit;
  final String guestHours;
  const GuestRules(this.maxNightsPerMonth, this.maxDurationHours, this.requiresHostUnit, this.guestHours);

  factory GuestRules.fromJson(Map<String, dynamic>? j) => GuestRules(
        (j?['max_nights_per_month'] as num?)?.toInt() ?? 0,
        (j?['max_duration_hours'] as num?)?.toInt() ?? 0,
        j?['requires_host_unit'] == true,
        '${j?['guest_hours'] ?? ''}',
      );
}

class Property {
  final String propertyId, name, campus;
  final double lat, lng;
  final double radiusM;
  final double? distanceM;
  final String? vendorId;
  final GuestRules guestRules;
  final bool towEnforced;
  final String? notes;
  const Property({
    required this.propertyId,
    required this.name,
    required this.campus,
    required this.lat,
    required this.lng,
    required this.radiusM,
    this.distanceM,
    this.vendorId,
    required this.guestRules,
    required this.towEnforced,
    this.notes,
  });

  factory Property.fromJson(Map<String, dynamic> j) => Property(
        propertyId: j['property_id'],
        name: j['name'] ?? '',
        campus: j['campus'] ?? '',
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        radiusM: (j['radius_m'] as num?)?.toDouble() ?? 100,
        distanceM: (j['distance_m'] as num?)?.toDouble(),
        vendorId: j['vendor_id'],
        guestRules: GuestRules.fromJson(j['guest_rules']),
        towEnforced: j['tow_enforced'] == true,
        notes: j['notes'],
      );

  bool get hasPortal => vendorId != null;
  bool get inside => distanceM != null && distanceM! <= radiusM;
}

class PropertyRef {
  final String propertyId, name;
  const PropertyRef(this.propertyId, this.name);
  factory PropertyRef.fromJson(Map<String, dynamic> j) => PropertyRef(j['property_id'], j['name'] ?? '');
}

class Host {
  final String? name, unit;
  const Host({this.name, this.unit});
  factory Host.fromJson(Map<String, dynamic> j) => Host(name: j['name'], unit: j['unit']);
  Map<String, dynamic> toJson() => {'name': name, 'unit': unit};
}

class RegistrationStep {
  final String name;
  final StepStatus status;
  final String? at;
  const RegistrationStep(this.name, this.status, this.at);
  factory RegistrationStep.fromJson(Map<String, dynamic> j) =>
      RegistrationStep(j['name'], StepStatus.parse('${j['status']}'), j['at']);
}

class NeedsUser {
  final NeedsUserReason reason;
  final String message;
  final String? field, portalUrl;
  const NeedsUser(this.reason, this.message, this.field, this.portalUrl);
  factory NeedsUser.fromJson(Map<String, dynamic> j) =>
      NeedsUser(NeedsUserReason.parse('${j['reason']}'), j['message'] ?? '', j['field'], j['portal_url']);
}

class Proof {
  final String? confirmationNumber;
  final DateTime? expiresAt;
  final List<String> screenshotUrls;
  const Proof(this.confirmationNumber, this.expiresAt, this.screenshotUrls);
  factory Proof.fromJson(Map<String, dynamic> j) => Proof(
        j['confirmation_number'],
        j['expires_at'] == null ? null : DateTime.tryParse(j['expires_at']),
        [for (final u in (j['screenshot_urls'] as List? ?? const [])) '$u'],
      );
}

class ApiErrorBody {
  final String code, message;
  const ApiErrorBody(this.code, this.message);
  factory ApiErrorBody.fromJson(Map<String, dynamic> j) => ApiErrorBody(j['code'] ?? '', j['message'] ?? '');
}

class Registration {
  final String registrationId;
  final RegistrationStatus status;
  final String summary;
  final PropertyRef property;
  final List<PropertyRef> alternatives;
  final Vehicle vehicle;
  final Role role;
  final Host? host;
  final int durationHours;
  final List<RegistrationStep> steps;
  final NeedsUser? needsUser;
  final Proof? proof;
  final ApiErrorBody? error;
  final DateTime? createdAt;

  const Registration({
    required this.registrationId,
    required this.status,
    required this.summary,
    required this.property,
    required this.alternatives,
    required this.vehicle,
    required this.role,
    this.host,
    required this.durationHours,
    required this.steps,
    this.needsUser,
    this.proof,
    this.error,
    this.createdAt,
  });

  factory Registration.fromJson(Map<String, dynamic> j) => Registration(
        registrationId: j['registration_id'],
        status: RegistrationStatus.parse('${j['status']}'),
        summary: j['summary'] ?? '',
        property: PropertyRef.fromJson(j['property']),
        alternatives: [for (final a in (j['alternatives'] as List? ?? const [])) PropertyRef.fromJson(a)],
        vehicle: Vehicle.fromJson(j['vehicle']),
        role: j['role'] == 'resident' ? Role.resident : Role.visitor,
        host: j['host'] == null ? null : Host.fromJson(j['host']),
        durationHours: (j['duration_hours'] as num?)?.toInt() ?? 0,
        steps: [for (final s in (j['steps'] as List? ?? const [])) RegistrationStep.fromJson(s)],
        needsUser: j['needs_user'] == null ? null : NeedsUser.fromJson(j['needs_user']),
        proof: j['proof'] == null ? null : Proof.fromJson(j['proof']),
        error: j['error'] == null ? null : ApiErrorBody.fromJson(j['error']),
        createdAt: j['created_at'] == null ? null : DateTime.tryParse(j['created_at']),
      );
}

class VehicleVision {
  final String plate, state, make, model, color;
  final double confidence;
  const VehicleVision(this.plate, this.state, this.make, this.model, this.color, this.confidence);
  factory VehicleVision.fromJson(Map<String, dynamic> j) => VehicleVision(j['plate'] ?? '',
      j['state'] ?? '', j['make'] ?? '', j['model'] ?? '', j['color'] ?? '', (j['confidence'] as num?)?.toDouble() ?? 0);
}
