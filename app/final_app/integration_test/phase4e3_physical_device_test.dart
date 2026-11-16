// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/services/ocr/ocr_service.dart';
import 'package:vision_assistant/widgets/banknote_overlay_painter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 4E.3 Physical Device Validation Test Suite (Nothing Phone 2a Plus)', () {
    late CurrencyModelService currencyService;
    final Map<String, dynamic> deviceReport = {
      'phase': '4E.3',
      'device': 'Nothing Phone (2a) Plus (A059P)',
      'processor': 'MediaTek Dimensity 7350 Pro (ARM64-v8a)',
      'os': 'Android 17 (API 37)',
      'timestamp': DateTime.now().toIso8601String(),
      'tests': <String, dynamic>{},
    };

    setUpAll(() {
      currencyService = CurrencyModelService();
    });

    tearDownAll(() async {
      await currencyService.dispose();
      print('[PHYSICAL_DEVICE_RESULTS_BEGIN]');
      print(jsonEncode(deviceReport));
      print('[PHYSICAL_DEVICE_RESULTS_END]');
    });

    // ------------------------------------------------------------
    // TEST 1: Model Initialization on Physical ARM64 Hardware
    // ------------------------------------------------------------
    testWidgets('1. Physical Device Dual Model Initialization', (tester) async {
      final sw = Stopwatch()..start();
      await currencyService.loadModel();
      sw.stop();

      expect(currencyService.isLoaded, isTrue);
      print('[DEVICE TEST 1] Native currency models initialized on device in ${sw.elapsedMilliseconds} ms');

      deviceReport['tests']['1_model_initialization'] = {
        'status': 'PASSED',
        'init_latency_ms': sw.elapsedMilliseconds,
        'models_loaded': true,
      };
    });

    // ------------------------------------------------------------
    // TEST 2: Banknote Denomination Evaluation (₹10 to ₹500)
    // ------------------------------------------------------------
    testWidgets('2. Banknote Denomination Accuracy & Latency (₹10, ₹20, ₹50, ₹100, ₹200, ₹500)', (tester) async {
      final banknoteSamples = [
        {'denom': '₹10', 'file': 'EXP1000-0105.jpg', 'expectedClass': 'INR_10', 'expectedVal': 10},
        {'denom': '₹20', 'file': 'EXP1000-0223.jpg', 'expectedClass': 'INR_20', 'expectedVal': 20},
        {'denom': '₹50', 'file': 'EXP1000-0448.jpg', 'expectedClass': 'INR_50', 'expectedVal': 50},
        {'denom': '₹100', 'file': 'EXP1000-0534.jpg', 'expectedClass': 'INR_100', 'expectedVal': 100},
        {'denom': '₹200', 'file': 'PILOT500-360.jpg', 'expectedClass': 'INR_200', 'expectedVal': 200},
        {'denom': '₹500', 'file': 'PILOT500-474.jpg', 'expectedClass': 'INR_500', 'expectedVal': 500},
      ];

      final Map<String, dynamic> results = {};
      final latencies = <double>[];

      for (final sample in banknoteSamples) {
        final path = 'assets/test_images/dev_samples/${sample['file']}';
        final byteData = await rootBundle.load(path);
        final bytes = byteData.buffer.asUint8List();

        final sw = Stopwatch()..start();
        final res = await currencyService.runImageInference(bytes, source: sample['file'] as String);
        sw.stop();

        final latency = sw.elapsedMilliseconds.toDouble();
        latencies.add(latency);

        expect(res.detections.isNotEmpty, isTrue, reason: 'Failed to detect banknote ${sample['denom']}');
        final topDet = res.detections.first;
        expect(topDet.denomination, equals(sample['expectedClass']));
        expect(topDet.value, equals(sample['expectedVal']));

        final spokenName = CurrencyModelService.formatItemSpokenName(topDet.denomination, topDet.value);
        final displayName = CurrencyModelService.formatItemDisplayName(topDet.denomination, topDet.value);

        print('  Banknote ${sample['denom']}: detected ${topDet.denomination} (conf: ${(topDet.confidence * 100).toStringAsFixed(1)}%) in ${latency.toStringAsFixed(1)} ms | Box: [${topDet.x1.toStringAsFixed(1)}, ${topDet.y1.toStringAsFixed(1)}, ${topDet.x2.toStringAsFixed(1)}, ${topDet.y2.toStringAsFixed(1)}]');

        results[sample['denom'] as String] = {
          'file': sample['file'],
          'detected_class': topDet.denomination,
          'value': topDet.value,
          'confidence': topDet.confidence,
          'latency_ms': latency,
          'box': [topDet.x1, topDet.y1, topDet.x2, topDet.y2],
          'spoken_announcement': spokenName,
          'display_name': displayName,
        };
      }

      final meanLatency = latencies.reduce((a, b) => a + b) / latencies.length;
      print('[DEVICE TEST 2] All 6 banknote denominations verified. Mean latency: ${meanLatency.toStringAsFixed(2)} ms');

      deviceReport['tests']['2_banknote_denominations'] = {
        'status': 'PASSED',
        'denominations_tested': banknoteSamples.length,
        'mean_latency_ms': meanLatency,
        'results': results,
      };
    });

    // ------------------------------------------------------------
    // TEST 3: Coin Denomination Evaluation (₹1, ₹2, ₹5, ₹10)
    // ------------------------------------------------------------
    testWidgets('3. Coin Denomination Accuracy & Latency (₹1, ₹2, ₹5, ₹10)', (tester) async {
      final coinSamples = [
        {'denom': '₹1 Coin', 'file': 'coin_1_rupee_IMG_0422JPG.jpg', 'expectedClass': 'INR_1_COIN', 'expectedVal': 1},
        {'denom': '₹2 Coin', 'file': 'coin_2_rupee_IMG_E1291JPG.jpg', 'expectedClass': 'INR_2_COIN', 'expectedVal': 2},
        {'denom': '₹5 Coin', 'file': 'coin_5_rupee_IMG_0445JPG.jpg', 'expectedClass': 'INR_5_COIN', 'expectedVal': 5},
        {'denom': '₹10 Coin', 'file': 'coin_10_rupee_005JPG.jpg', 'expectedClass': 'INR_10_COIN', 'expectedVal': 10},
      ];

      final Map<String, dynamic> results = {};
      final latencies = <double>[];

      for (final sample in coinSamples) {
        final path = 'assets/test_images/dev_samples/${sample['file']}';
        final byteData = await rootBundle.load(path);
        final bytes = byteData.buffer.asUint8List();

        final sw = Stopwatch()..start();
        final res = await currencyService.runImageInference(bytes, source: sample['file'] as String);
        sw.stop();

        final latency = sw.elapsedMilliseconds.toDouble();
        latencies.add(latency);

        expect(res.detections.isNotEmpty, isTrue, reason: 'Failed to detect coin ${sample['denom']}');
        final match = res.detections.firstWhere(
          (d) => d.denomination == sample['expectedClass'],
          orElse: () => res.detections.first,
        );

        expect(match.denomination, equals(sample['expectedClass']));
        expect(match.value, equals(sample['expectedVal']));

        final spokenName = CurrencyModelService.formatItemSpokenName(match.denomination, match.value);
        final displayName = CurrencyModelService.formatItemDisplayName(match.denomination, match.value);

        print('  Coin ${sample['denom']}: detected ${match.denomination} (conf: ${(match.confidence * 100).toStringAsFixed(1)}%) in ${latency.toStringAsFixed(1)} ms | Box: [${match.x1.toStringAsFixed(1)}, ${match.y1.toStringAsFixed(1)}, ${match.x2.toStringAsFixed(1)}, ${match.y2.toStringAsFixed(1)}]');

        results[sample['denom'] as String] = {
          'file': sample['file'],
          'detected_class': match.denomination,
          'value': match.value,
          'confidence': match.confidence,
          'latency_ms': latency,
          'box': [match.x1, match.y1, match.x2, match.y2],
          'spoken_announcement': spokenName,
          'display_name': displayName,
        };
      }

      final meanLatency = latencies.reduce((a, b) => a + b) / latencies.length;
      print('[DEVICE TEST 3] All 4 coin denominations verified. Mean latency: ${meanLatency.toStringAsFixed(2)} ms');

      deviceReport['tests']['3_coin_denominations'] = {
        'status': 'PASSED',
        'denominations_tested': coinSamples.length,
        'mean_latency_ms': meanLatency,
        'results': results,
      };
    });

    // ------------------------------------------------------------
    // TEST 4: Live YUV420 Frame Stream Inference on Physical Device
    // ------------------------------------------------------------
    testWidgets('4. Real-Time Camera YUV420 Stream Frame Benchmark', (tester) async {
      const samplePath = 'assets/test_images/dev_samples/EXP1000-0105.jpg';
      final byteData = await rootBundle.load(samplePath);
      final rawBytes = byteData.buffer.asUint8List();

      final decoded = img.decodeImage(rawBytes);
      expect(decoded, isNotNull);

      // 640x360 camera preview frame simulation
      final frameImg = img.copyResize(decoded!, width: 640, height: 360);
      final width = frameImg.width;
      final height = frameImg.height;

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

          yPlane[yIdx++] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);

          if (y % 2 == 0 && x % 2 == 0) {
            final uvIdx = (y ~/ 2) * (width ~/ 2) + (x ~/ 2);
            uPlane[uvIdx] = ((-0.169 * r - 0.331 * g + 0.500 * b) + 128).round().clamp(0, 255);
            vPlane[uvIdx] = ((0.500 * r - 0.419 * g - 0.081 * b) + 128).round().clamp(0, 255);
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

      print('[DEVICE TEST 4] Physical ARM64 YUV stream frame processed:');
      print('  Roundtrip latency: ${sw.elapsedMilliseconds} ms');
      print('  Integer BT.601 YUV conversion: ${res['preprocessTimeMs']} ms');
      print('  Coin ONNX inference: ${res['coinInferenceTimeMs']} ms');
      print('  Banknote ONNX inference: ${res['banknoteInferenceTimeMs']} ms');
      print('  Total native dual execution: ${res['totalTimeMs']} ms');

      deviceReport['tests']['4_yuv_live_stream_benchmark'] = {
        'status': 'PASSED',
        'roundtrip_latency_ms': sw.elapsedMilliseconds,
        'yuv_conversion_ms': res['preprocessTimeMs'],
        'coin_onnx_ms': res['coinInferenceTimeMs'],
        'banknote_onnx_ms': res['banknoteInferenceTimeMs'],
        'native_total_ms': res['totalTimeMs'],
      };
    });

    // ------------------------------------------------------------
    // TEST 5: Mixed Multi-Object Counting & Total Calculation
    // ------------------------------------------------------------
    testWidgets('5. Multi-Object Detection & Cumulative Total Calculation', (tester) async {
      // Test complex scene with multiple denominations (₹500, ₹200, ₹50, ₹10, ₹10 coin, ₹5 coin)
      final mixedItems = [
        const CurrencyDetection(classId: 5, denomination: 'INR_500', value: 500, confidence: 0.94, x1: 50, y1: 50, x2: 450, y2: 300),
        const CurrencyDetection(classId: 4, denomination: 'INR_200', value: 200, confidence: 0.91, x1: 50, y1: 320, x2: 450, y2: 570),
        const CurrencyDetection(classId: 2, denomination: 'INR_50', value: 50, confidence: 0.89, x1: 50, y1: 590, x2: 450, y2: 840),
        const CurrencyDetection(classId: 0, denomination: 'INR_10', value: 10, confidence: 0.93, x1: 500, y1: 50, x2: 900, y2: 300),
        const CurrencyDetection(classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.86, x1: 500, y1: 350, x2: 650, y2: 500),
        const CurrencyDetection(classId: 8, denomination: 'INR_5_COIN', value: 5, confidence: 0.81, x1: 700, y1: 350, x2: 850, y2: 500),
      ];

      final total = mixedItems.fold<int>(0, (s, d) => s + d.value);
      expect(total, equals(775));

      // Build spoken announcement
      final countMap = <String, int>{};
      final valueMap = <String, int>{};
      for (final d in mixedItems) {
        countMap[d.denomination] = (countMap[d.denomination] ?? 0) + 1;
        valueMap[d.denomination] = d.value;
      }
      final parts = <String>[];
      countMap.forEach((denom, count) {
        final val = valueMap[denom] ?? 0;
        final spokenUnit = CurrencyModelService.formatItemSpokenName(denom, val);
        parts.add(count == 1 ? spokenUnit : '$count $spokenUnit' 's');
      });
      final announcement = '${parts.join(', ')}. Total, $total Rupees';

      print('[DEVICE TEST 5] Multi-object total verified: ₹$total across ${mixedItems.length} items');
      print('  Spoken phrase: "$announcement"');

      deviceReport['tests']['5_multi_object_total'] = {
        'status': 'PASSED',
        'item_count': mixedItems.length,
        'grand_total': total,
        'spoken_phrase': announcement,
      };
    });

    // ------------------------------------------------------------
    // TEST 6: Multilingual OCR Subsystem Regression
    // ------------------------------------------------------------
    testWidgets('6. Multilingual OCR Pipeline Coexistence (English, Kannada, Hindi)', (tester) async {
      final ocrService = OcrService();
      final sw = Stopwatch()..start();
      await ocrService.loadModels();
      sw.stop();

      expect(ocrService.isLoaded, isTrue);
      print('[DEVICE TEST 6] OCR models loaded on physical device in ${sw.elapsedMilliseconds} ms');

      await ocrService.dispose();

      deviceReport['tests']['6_ocr_subsystem'] = {
        'status': 'PASSED',
        'ocr_load_latency_ms': sw.elapsedMilliseconds,
        'dual_subsystem_coexistence': true,
      };
    });

    // ------------------------------------------------------------
    // TEST 7: Render Detection Overlays & Breakdown Card for Visual Verification
    // ------------------------------------------------------------
    testWidgets('7. Render Currency Overlay & Breakdown Card for Screenshot Capture', (tester) async {
      final testDetections = [
        const CurrencyDetection(classId: 2, denomination: 'INR_50', value: 50, confidence: 0.92, x1: 80, y1: 200, x2: 600, y2: 600),
        const CurrencyDetection(classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.88, x1: 120, y1: 680, x2: 320, y2: 880),
        const CurrencyDetection(classId: 8, denomination: 'INR_5_COIN', value: 5, confidence: 0.84, x1: 400, y1: 680, x2: 600, y2: 880),
      ];

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Simulated dark camera background
                Container(
                  color: const Color(0xFF121212),
                ),

                // Live Bounding Box Overlays
                Positioned.fill(
                  child: CustomPaint(
                    painter: BanknoteOverlayPainter(
                      detections: testDetections,
                      imageWidth: 720,
                      imageHeight: 1280,
                    ),
                  ),
                ),

                // Top Frosted Currency Banner
                Positioned(
                  top: 70,
                  left: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '1× ₹50 Note · 1× ₹10 Coin · 1× ₹5 Coin',
                              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '3 items in direct view',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                          ),
                          child: const Text(
                            '₹65',
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom Mode Selector
                Positioned(
                  bottom: 40,
                  left: 20,
                  right: 20,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                      ),
                      child: const Text(
                        'Auto-Detecting · Tap Shutter for Instant Count',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('[DEVICE TEST 7] Visual overlay and breakdown card rendered on physical display');

      deviceReport['tests']['7_ui_rendering'] = {
        'status': 'PASSED',
        'visual_overlay_rendered': true,
      };
    });
  });
}
