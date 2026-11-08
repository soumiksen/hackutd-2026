import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_error.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../models/models.dart';
import '../../services/session.dart';

/// welcome -> car photo -> car fields -> profile + consent + notify channel -> done.
class OnboardingScreen extends ConsumerStatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int step = 0;
  bool busy = false;
  String? visionNote;
  XFile? photo;

  final plate = TextEditingController();
  final state = TextEditingController(text: 'TX');
  final make = TextEditingController();
  final model = TextEditingController();
  final color = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController(text: '+1');
  final email = TextEditingController();
  bool consent = true;
  NotifyChannel channel = NotifyChannel.both;

  final carForm = GlobalKey<FormState>();
  final profileForm = GlobalKey<FormState>();

  Future<void> pickPhoto(ImageSource source) async {
    final f = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
    if (f == null) return;
    setState(() {
      photo = f;
      busy = true;
      visionNote = null;
    });
    try {
      final v = await ref.read(apiProvider).analyzeVehiclePhoto(f);
      if (v.plate.isNotEmpty) plate.text = v.plate;
      if (v.state.isNotEmpty) state.text = v.state;
      if (v.make.isNotEmpty) make.text = v.make;
      if (v.model.isNotEmpty) model.text = v.model;
      if (v.color.isNotEmpty) color.text = v.color;
      visionNote = 'Read by Nemotron. Check the details below.';
    } on ApiError catch (e) {
      visionNote = e.code == 'llm_unavailable'
          ? "Couldn't read the photo right now. Type the details in."
          : e.message;
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          step = 2;
        });
      }
    }
  }

  Future<void> finish() async {
    if (!profileForm.currentState!.validate()) return;
    setState(() => busy = true);
    final api = ref.read(apiProvider);
    try {
      await api.upsertUser(User(
        name: name.text.trim(),
        phone: phone.text.replaceAll(RegExp(r'[\s()-]'), ''),
        email: email.text.trim(),
        consentRegister: consent,
        notifyChannel: channel,
      ));
      final v = await api.createVehicle(Vehicle(
        plate: plate.text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''),
        state: state.text.trim().toUpperCase(),
        make: make.text.trim(),
        model: model.text.trim(),
        color: color.text.trim(),
      ));
      await ref.read(sessionProvider).completeOnboarding(vehicleId: v.vehicleId!, name: name.text.trim());
      widget.onDone();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String? required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pages = [_welcome(t), _photo(t), _car(t), _profile(t)];
    return Scaffold(
      body: SafeArea(
        child: PhoneFrame(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (step > 0)
                Row(children: [
                  IconButton(
                      onPressed: busy ? null : () => setState(() => step -= 1), icon: const Icon(Icons.arrow_back)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: LinearProgressIndicator(
                          value: step / 3, minHeight: 6, backgroundColor: P.line, color: P.sign),
                    ),
                  ),
                  const SizedBox(width: 12),
                ]),
              Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: pages[step])),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _welcome(TextTheme t) => Column(
        key: const ValueKey(0),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: P.sign, borderRadius: BorderRadius.circular(16)),
            alignment: Alignment.center,
            child: const Text('P',
                style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900, height: 1)),
          ),
          const SizedBox(height: 24),
          Text('Parkour', style: t.displaySmall),
          const SizedBox(height: 6),
          Text('You park. We handle it.', style: t.headlineSmall?.copyWith(color: P.sign)),
          const SizedBox(height: 16),
          Text(
            'Pull into an apartment complex and Parkour registers your car on its guest parking portal, '
            'then keeps the proof. One tap from you, at most two.',
            style: t.bodyLarge?.copyWith(color: P.muted, height: 1.4),
          ),
          const Spacer(flex: 2),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: () => setState(() => step = 1), child: const Text('Get started')),
          ),
        ],
      );

  Widget _photo(TextTheme t) => Column(
        key: const ValueKey(1),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Text('Snap your car', style: t.headlineMedium),
          const SizedBox(height: 8),
          Text('Take a photo that shows the back plate. The agent reads the plate, make, model and color for you.',
              style: t.bodyLarge?.copyWith(color: P.muted)),
          const SizedBox(height: 24),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: P.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: P.line, width: 2),
              ),
              child: Center(
                child: busy
                    ? const Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Reading your car…'),
                      ])
                    : const Icon(Icons.directions_car_filled_outlined, size: 96, color: P.line),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : () => pickPhoto(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Take photo'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: busy ? null : () => pickPhoto(ImageSource.gallery),
            child: const Text('Choose from photos'),
          ),
          TextButton(onPressed: busy ? null : () => setState(() => step = 2), child: const Text('Type it in instead')),
        ],
      );

  Widget _car(TextTheme t) => Form(
        key: carForm,
        child: ListView(key: const ValueKey(2), children: [
          const SizedBox(height: 16),
          Text('Your car', style: t.headlineMedium),
          if (visionNote != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: P.agentSoft, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.auto_awesome, color: P.agent, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(visionNote!, style: const TextStyle(color: P.agent))),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
                flex: 3,
                child: TextFormField(
                    controller: plate,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(labelText: 'Plate'),
                    validator: required)),
            const SizedBox(width: 12),
            Expanded(
                child: TextFormField(
                    controller: state,
                    maxLength: 2,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(labelText: 'State', counterText: ''),
                    validator: (v) => (v ?? '').trim().length == 2 ? null : '2 letters')),
          ]),
          const SizedBox(height: 12),
          TextFormField(controller: make, decoration: const InputDecoration(labelText: 'Make'), validator: required),
          const SizedBox(height: 12),
          TextFormField(controller: model, decoration: const InputDecoration(labelText: 'Model'), validator: required),
          const SizedBox(height: 12),
          TextFormField(controller: color, decoration: const InputDecoration(labelText: 'Color'), validator: required),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              if (carForm.currentState!.validate()) setState(() => step = 3);
            },
            child: const Text('Looks right'),
          ),
        ]),
      );

  Widget _profile(TextTheme t) => Form(
        key: profileForm,
        child: ListView(key: const ValueKey(3), children: [
          const SizedBox(height: 16),
          Text('About you', style: t.headlineMedium),
          const SizedBox(height: 8),
          Text('Parking portals ask for these. You type them once.', style: t.bodyLarge?.copyWith(color: P.muted)),
          const SizedBox(height: 20),
          TextFormField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
              validator: required),
          const SizedBox(height: 12),
          TextFormField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Mobile phone', helperText: 'With country code, e.g. +14695550100'),
            validator: (v) => RegExp(r'^\+[1-9]\d{6,14}$').hasMatch((v ?? '').replaceAll(RegExp(r'[\s()-]'), ''))
                ? null
                : 'Use the format +14695550100',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
            validator: (v) => (v ?? '').contains('@') ? null : 'Enter an email',
          ),
          const SizedBox(height: 20),
          Card(
            child: SwitchListTile(
              value: consent,
              onChanged: (v) => setState(() => consent = v),
              title: const Text('Allow Parkour to register on my behalf'),
              subtitle: const Text('The agent only submits after you tap Register or reply YES.'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Where should we ask you?', style: t.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<NotifyChannel>(
            segments: const [
              ButtonSegment(value: NotifyChannel.app, label: Text('App')),
              ButtonSegment(value: NotifyChannel.message, label: Text('Messages')),
              ButtonSegment(value: NotifyChannel.both, label: Text('Both')),
            ],
            selected: {channel},
            onSelectionChanged: (s) => setState(() => channel = s.first),
          ),
          const SizedBox(height: 6),
          Text('Messages arrive in iMessage or SMS. Reply YES to register.',
              style: t.bodySmall?.copyWith(color: P.muted)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : finish,
            child: busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Finish'),
          ),
        ]),
      );
}
