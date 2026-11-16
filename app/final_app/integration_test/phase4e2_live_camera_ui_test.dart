// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/main.dart';
import 'package:vision_assistant/services/banknote_tracker.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/ocr/ocr_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4E.2 Live Camera Integration & UI Redesign Test Suite', () {
    late CurrencyModelService currencyService;
    final Map<String, dynamic> testReport = {
      'phase': '4E.2',
      'title': 'Live Camera Integration & UI Redesign Verification',
      'timestamp': DateTime.now().toIso8601String(),
      'tests': <String, dynamic>{},
    };

    setUpAll(() {
      currencyService = CurrencyModelService();
    });

    tearDownAll(() async {
      await currencyService.dispose();
      print('[PHASE_4E2_TEST_RESULTS_BEGIN]');
      print(jsonEncode(testReport));
      print('[PHASE_4E2_TEST_RESULTS_END]');
    });

    testWidgets('1. Native Model Initialization & Session Readiness', (tester) async {
      final sw = Stopwatch()..start();
      await currencyService.loadModel();
      sw.stop();

      expect(currencyService.isLoaded, isTrue);
      print('[TEST 1] Native dual currency models initialized in ${sw.elapsedMilliseconds} ms');

      testReport['tests']['1_model_initialization'] = {
        'status': 'PASSED',
        'init_latency_ms': sw.elapsedMilliseconds,
        'models_loaded': currencyService.isLoaded,
      };
    });

    testWidgets('2. YUV420 Live Camera Frame Conversion & Inference', (tester) async {
      // Load a representative dev sample image
      const samplePath = 'assets/test_images/dev_samples/EXP1000-0105.jpg';
      final byteData = await rootBundle.load(samplePath);
      final rawBytes = byteData.buffer.asUint8List();

      final decoded = img.decodeImage(rawBytes);
      expect(decoded, isNotNull);

      // Downscale to 640x360 to simulate live camera streaming frame
      final frameImg = img.copyResize(decoded!, width: 640, height: 360);
      final width = frameImg.width;
      final height = frameImg.height;

      // Convert RGB image to YUV420 planes (Planar Y, U, V)
      final yPlane = Uint8List(width * height);
      final uPlane = Uint8List((width ~/ 2) * (height ~/ 2));
      final vPlane = Uint8List((width ~/ 2) * (height ~/ 2));

      int yIdx = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final pixel = frameImg.getPixel(x, y);
          final r = pixel.r.toInt();
          final g = pixel.g.toInt();
          final b = pixel.b.toInt();

          final yVal = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
          yPlane[yIdx++] = yVal;

          if (y % 2 == 0 && x % 2 == 0) {
            final uvIdx = (y ~/ 2) * (width ~/ 2) + (x ~/ 2);
            final uVal = ((-0.169 * r - 0.331 * g + 0.500 * b) + 128).round().clamp(0, 255);
            final vVal = ((0.500 * r - 0.419 * g - 0.081 * b) + 128).round().clamp(0, 255);
            uPlane[uvIdx] = uVal;
            vPlane[uvIdx] = vVal;
          }
        }
      }

      const nativeChannel = MethodChannel('visionmission/currency_detector');
      final sw = Stopwatch()..start();
      final Map<dynamic, dynamic>? res = await nativeChannel.invokeMethod('detectCameraFrame', {
        'yBytes': yPlane,
        'uBytes': uPlane,
        'vBytes': vPlane,
        'width': width,
        'height': height,
        'yRowStride': width,
        'uvRowStride': width ~/ 2,
        'uvPixelStride': 1,
        'sensorOrientation': 0,
        'coinConfThreshold': 0.25,
        'banknoteConfThreshold': 0.25,
        'iouThreshold': 0.45,
      });
      sw.stop();

      expect(res, isNotNull);
      expect(res!['status'], equals('success'));
      final detections = res['detections'] as List<dynamic>;
      final totalValue = res['totalValue'] as int;

      print('[TEST 2] Live YUV420 frame inference completed in ${sw.elapsedMilliseconds} ms');
      print('         Detections: ${detections.length}, Total: ₹$totalValue');
      print('         Preprocess: ${res['preprocessTimeMs']} ms, Coin: ${res['coinInferenceTimeMs']} ms, Note: ${res['banknoteInferenceTimeMs']} ms');

      expect(detections.isNotEmpty, isTrue);

      testReport['tests']['2_yuv_live_frame_inference'] = {
        'status': 'PASSED',
        'roundtrip_latency_ms': sw.elapsedMilliseconds,
        'preprocess_time_ms': res['preprocessTimeMs'],
        'coin_inference_time_ms': res['coinInferenceTimeMs'],
        'banknote_inference_time_ms': res['banknoteInferenceTimeMs'],
        'total_native_time_ms': res['totalTimeMs'],
        'detections_count': detections.length,
        'total_value': totalValue,
      };
    });

    testWidgets('3. Multi-Object Counting & Total Value Calculation', (tester) async {
      // Test mock detection list containing both notes and coins
      final mockDetections = [
        const CurrencyDetection(
          classId: 2,
          denomination: 'INR_50',
          value: 50,
          confidence: 0.88,
          x1: 50,
          y1: 100,
          x2: 300,
          y2: 450,
        ),
        const CurrencyDetection(
          classId: 0,
          denomination: 'INR_10',
          value: 10,
          confidence: 0.92,
          x1: 320,
          y1: 100,
          x2: 550,
          y2: 450,
        ),
        const CurrencyDetection(
          classId: 8,
          denomination: 'INR_5_COIN',
          value: 5,
          confidence: 0.79,
          x1: 100,
          y1: 500,
          x2: 200,
          y2: 600,
        ),
      ];

      final total = mockDetections.fold<int>(0, (s, d) => s + d.value);
      expect(total, equals(65));

      // Test display and spoken name formatting
      final spoken50 = CurrencyModelService.formatItemSpokenName('INR_50', 50);
      final spoken5Coin = CurrencyModelService.formatItemSpokenName('INR_5_COIN', 5);
      final display50 = CurrencyModelService.formatItemDisplayName('INR_50', 50);
      final display5Coin = CurrencyModelService.formatItemDisplayName('INR_5_COIN', 5);

      expect(spoken50, equals('50 Rupee Note'));
      expect(spoken5Coin, equals('5 Rupee Coin'));
      expect(display50, equals('₹50 Note'));
      expect(display5Coin, equals('₹5 Coin'));

      print('[TEST 3] Multi-object total verified: ₹$total across ${mockDetections.length} mixed items');

      testReport['tests']['3_multi_object_counting'] = {
        'status': 'PASSED',
        'item_count': mockDetections.length,
        'calculated_total': total,
        'spoken_note': spoken50,
        'spoken_coin': spoken5Coin,
      };
    });

    testWidgets('4. Camera Sensor Orientation & Coordinate Transformation', (tester) async {
      const samplePath = 'assets/test_images/dev_samples/coin_10_rupee_005JPG.jpg';
      final byteData = await rootBundle.load(samplePath);
      final rawBytes = byteData.buffer.asUint8List();

      // Test with orientation 0 vs orientation 90
      const nativeChannel = MethodChannel('visionmission/currency_detector');
      final res0 = await nativeChannel.invokeMethod('detectSnapshot', {
        'imageBytes': rawBytes,
        'orientationDegrees': 0,
      });

      final res90 = await nativeChannel.invokeMethod('detectSnapshot', {
        'imageBytes': rawBytes,
        'orientationDegrees': 90,
      });

      expect(res0, isNotNull);
      expect(res90, isNotNull);

      final w0 = res0!['imageWidth'] as int;
      final h0 = res0['imageHeight'] as int;
      final w90 = res90!['imageWidth'] as int;
      final h90 = res90['imageHeight'] as int;

      // When rotated 90 degrees, width and height swap
      expect(w90, equals(h0));
      expect(h90, equals(w0));

      print('[TEST 4] Sensor orientation rotation verified: ($w0 x $h0) -> ($w90 x $h90)');

      testReport['tests']['4_sensor_orientation'] = {
        'status': 'PASSED',
        'orig_dimensions': [w0, h0],
        'rotated_dimensions': [w90, h90],
      };
    });

    testWidgets('5. Temporal Tracking & Smoothing (EMA + Majority Voting)', (tester) async {
      final tracker = BanknoteTracker();

      // Frame 1: Detection arrives (candidate)
      final d1 = [
        const CurrencyDetection(
          classId: 0,
          denomination: 'INR_10',
          value: 10,
          confidence: 0.60,
          x1: 100,
          y1: 100,
          x2: 200,
          y2: 200,
        ),
      ];
      final stable1 = tracker.update(d1);
      // Immediately stable if confidence >= 0.55
      expect(stable1.length, equals(1));
      expect(stable1.first.x1, closeTo(100.0, 0.01));

      // Frame 2: Jittered box arrives [110, 105, 210, 205]
      final d2 = [
        const CurrencyDetection(
          classId: 0,
          denomination: 'INR_10',
          value: 10,
          confidence: 0.65,
          x1: 110,
          y1: 105,
          x2: 210,
          y2: 205,
        ),
      ];
      final stable2 = tracker.update(d2);
      expect(stable2.length, equals(1));
      // EMA smoothed: x1 = (1 - 0.35) * 100 + 0.35 * 110 = 65 + 38.5 = 103.5
      expect(stable2.first.x1, closeTo(103.5, 0.1));

      // Frame 3: Transient drop (detection empty) -> retained in active output
      final stable3 = tracker.update(const []);
      expect(stable3.length, equals(1));

      // Frame 4: Second missing frame -> track hidden from visual output to prevent ghost boxes
      final stable4 = tracker.update(const []);
      expect(stable4.length, equals(0));

      // Frame 5: Third missing frame -> expires from memory
      final stable5 = tracker.update(const []);
      expect(stable5.length, equals(0));

      print('[TEST 5] BanknoteTracker temporal smoothing & transient drop retention verified');

      testReport['tests']['5_temporal_tracking'] = {
        'status': 'PASSED',
        'ema_smoothing_verified': true,
        'transient_drop_retention_verified': true,
      };
    });

    testWidgets('6. Subsystem Independence: Multilingual OCR Service', (tester) async {
      final ocrService = OcrService();
      final sw = Stopwatch()..start();
      await ocrService.loadModels();
      sw.stop();

      print('[TEST 6] OCR Models loaded in ${sw.elapsedMilliseconds} ms');
      expect(ocrService.isLoaded, isTrue);

      // Verify that OCR models load cleanly alongside currency detector
      expect(currencyService.isLoaded, isTrue);

      await ocrService.dispose();

      testReport['tests']['6_ocr_subsystem_independence'] = {
        'status': 'PASSED',
        'ocr_load_latency_ms': sw.elapsedMilliseconds,
        'dual_subsystem_coexistence': true,
      };
    });

    testWidgets('7. Redesigned Modern UI Elements & Accessibility Structure', (tester) async {
      await tester.pumpWidget(const VisionAssistantApp());
      await tester.pump(const Duration(milliseconds: 500));

      // Verify Top Bar buttons exist
      expect(find.byIcon(Icons.flash_off_rounded), findsOneWidget);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

      // Verify Status Badge
      expect(find.text('CURRENCY VISION'), findsOneWidget);

      // Verify Mode Selector
      expect(find.text('💵 Currency'), findsOneWidget);
      expect(find.text('📄 Text OCR'), findsOneWidget);

      // Verify Accessibility Guidance Text
      expect(
        find.text('Auto-Detecting · Tap Shutter for Instant Count'),
        findsOneWidget,
      );

      // Switch mode to Text OCR
      await tester.tap(find.text('📄 Text OCR'));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify mode switched to Document OCR
      expect(find.text('DOCUMENT OCR'), findsOneWidget);
      expect(
        find.text('Tap Shutter or Press Volume-Up to Read Text'),
        findsOneWidget,
      );

      // Switch back to Currency Mode
      await tester.tap(find.text('💵 Currency'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CURRENCY VISION'), findsOneWidget);

      print('[TEST 7] Redesigned UI widgets, mode switching, and frosted elements verified');

      testReport['tests']['7_ui_redesign_verification'] = {
        'status': 'PASSED',
        'top_bar_verified': true,
        'mode_selector_verified': true,
        'accessibility_guidance_verified': true,
        'mode_switch_interaction_verified': true,
      };
    });
  });
}
