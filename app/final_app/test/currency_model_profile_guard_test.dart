import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('visionmission/currency_detector');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('refuses to run when Android falls back to the legacy currency profile',
      () async {
    var initCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      initCalls++;
      expect(call.method, 'initModels');
      return <String, Object?>{
        'status': 'success',
        'isCandidateMode': false,
        'isIdentityCandidate': false,
      };
    });

    final service = CurrencyModelService();

    await expectLater(
      service.loadModel(useCandidate: true),
      throwsA(isA<StateError>()),
    );

    expect(initCalls, 1);
    expect(service.isLoaded, isFalse);
    expect(service.isCandidateMode, isFalse);
  });

  test('accepts the final currency pipeline when Android activates it',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'initModels');
      return <String, Object?>{
        'status': 'success',
        'isCandidateMode': true,
        'isIdentityCandidate': true,
        'coinModelPath':
            '/data/user/0/com.sanetra.assistivevision/files/indian_coin_phase4n_candidate.onnx',
        'banknoteModelPath':
            '/data/user/0/com.sanetra.assistivevision/files/indian_banknote_phase4l_candidate.onnx',
        'noteVerifierPath':
            '/data/user/0/com.sanetra.assistivevision/files/n5_note_verifier.onnx',
        'coinVerifierPath':
            '/data/user/0/com.sanetra.assistivevision/files/indian_coin_verifier.onnx',
      };
    });

    final service = CurrencyModelService();
    await service.loadModel(useCandidate: true);

    expect(service.isLoaded, isTrue);
    expect(service.isCandidateMode, isTrue);
  });
}
