// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Verify Native Currency Engine Integration and Snapshot Inference',
      (WidgetTester tester) async {
    final currencyService = CurrencyModelService();

    // 1. Initialize native models via MethodChannel
    final stopwatchInit = Stopwatch()..start();
    await currencyService.loadModel();
    stopwatchInit.stop();

    expect(currencyService.isLoaded, isTrue);
    print('[TEST-INFO] Native dual models initialized in ${stopwatchInit.elapsedMilliseconds} ms');

    // 2. Discover test assets from AssetManifest
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allSamplePaths = manifest
        .listAssets()
        .where((p) => p.startsWith('assets/test_images/dev_samples/') &&
            (p.endsWith('.jpg') || p.endsWith('.JPG') || p.endsWith('.png')))
        .toList()
      ..sort();

    final coinPaths = allSamplePaths.where((p) => p.contains('coin_')).toList();
    final notePaths = allSamplePaths.where((p) => !p.contains('coin_')).toList();

    print('[TEST-INFO] Discovered ${coinPaths.length} coin samples and ${notePaths.length} banknote samples.');

    final Map<String, dynamic> testResults = {
      'status': 'SUCCESS',
      'init_latency_ms': stopwatchInit.elapsedMilliseconds,
      'coin_results': <String, dynamic>{},
      'banknote_results': <String, dynamic>{},
    };

    // 3. Evaluate Coin Images
    print('[TEST-INFO] Evaluating coin snapshot images...');
    final coinLatencies = <double>[];

    for (final path in coinPaths) {
      final fname = path.split('/').last;
      final byteData = await rootBundle.load(path);
      final bytes = byteData.buffer.asUint8List();

      final sw = Stopwatch()..start();
      final result = await currencyService.runImageInference(bytes, source: fname);
      sw.stop();

      final latencyMs = sw.elapsedMilliseconds.toDouble();
      coinLatencies.add(latencyMs);

      print('  Coin: $fname -> count=${result.detections.length}, total=₹${result.totalValue}, time=${latencyMs.toStringAsFixed(1)}ms');
      for (final d in result.detections) {
        print('    -> ${d.denomination} (${d.confidence.toStringAsFixed(4)}): [${d.x1.toStringAsFixed(1)}, ${d.y1.toStringAsFixed(1)}, ${d.x2.toStringAsFixed(1)}, ${d.y2.toStringAsFixed(1)}]');
      }

      testResults['coin_results'][fname] = {
        'count': result.detections.length,
        'total_value': result.totalValue,
        'latency_ms': latencyMs,
        'detections': result.detections
            .map((d) => {
                  'class_id': d.classId,
                  'denomination': d.denomination,
                  'value': d.value,
                  'confidence': d.confidence,
                  'box': [d.x1, d.y1, d.x2, d.y2],
                })
            .toList(),
      };
    }

    // 4. Evaluate Banknote Images
    print('[TEST-INFO] Evaluating banknote snapshot images...');
    final noteLatencies = <double>[];

    for (final path in notePaths) {
      final fname = path.split('/').last;
      final byteData = await rootBundle.load(path);
      final bytes = byteData.buffer.asUint8List();

      final sw = Stopwatch()..start();
      final result = await currencyService.runImageInference(bytes, source: fname);
      sw.stop();

      final latencyMs = sw.elapsedMilliseconds.toDouble();
      noteLatencies.add(latencyMs);

      print('  Note: $fname -> count=${result.detections.length}, total=₹${result.totalValue}, time=${latencyMs.toStringAsFixed(1)}ms');
      for (final d in result.detections) {
        print('    -> ${d.denomination} (${d.confidence.toStringAsFixed(4)}): [${d.x1.toStringAsFixed(1)}, ${d.y1.toStringAsFixed(1)}, ${d.x2.toStringAsFixed(1)}, ${d.y2.toStringAsFixed(1)}]');
      }

      testResults['banknote_results'][fname] = {
        'count': result.detections.length,
        'total_value': result.totalValue,
        'latency_ms': latencyMs,
        'detections': result.detections
            .map((d) => {
                  'class_id': d.classId,
                  'denomination': d.denomination,
                  'value': d.value,
                  'confidence': d.confidence,
                  'box': [d.x1, d.y1, d.x2, d.y2],
                })
            .toList(),
      };
    }

    final double meanCoinLatency = coinLatencies.isNotEmpty
        ? coinLatencies.reduce((a, b) => a + b) / coinLatencies.length
        : 0.0;
    final double meanNoteLatency = noteLatencies.isNotEmpty
        ? noteLatencies.reduce((a, b) => a + b) / noteLatencies.length
        : 0.0;

    print('[TEST-SUMMARY] Coin Mean Latency: ${meanCoinLatency.toStringAsFixed(2)} ms');
    print('[TEST-SUMMARY] Banknote Mean Latency: ${meanNoteLatency.toStringAsFixed(2)} ms');

    testResults['summary'] = {
      'mean_coin_latency_ms': meanCoinLatency,
      'mean_banknote_latency_ms': meanNoteLatency,
      'total_images_tested': coinPaths.length + notePaths.length,
      'coin_count': coinPaths.length,
      'banknote_count': notePaths.length,
    };

    // Output JSON for result collection
    final jsonString = jsonEncode(testResults);
    print('[SNAPSHOT_TEST_RESULT_BEGIN]');
    print(jsonString);
    print('[SNAPSHOT_TEST_RESULT_END]');

    // Clean up
    await currencyService.dispose();
  });
}
