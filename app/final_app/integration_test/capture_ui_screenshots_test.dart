// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vision_assistant/services/currency_model_service.dart';
import 'package:vision_assistant/widgets/banknote_overlay_painter.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Capture Screenshots 2 and 3 on Physical Device', (tester) async {
    final testDetections = [
      const CurrencyDetection(classId: 2, denomination: 'INR_50', value: 50, confidence: 0.92, x1: 90, y1: 280, x2: 630, y2: 720),
      const CurrencyDetection(classId: 9, denomination: 'INR_10_COIN', value: 10, confidence: 0.88, x1: 140, y1: 820, x2: 360, y2: 1040),
      const CurrencyDetection(classId: 8, denomination: 'INR_5_COIN', value: 5, confidence: 0.84, x1: 440, y1: 820, x2: 660, y2: 1040),
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
              // Viewport simulation
              Container(color: const Color(0xFF181818)),

              // Bounding boxes
              Positioned.fill(
                child: CustomPaint(
                  painter: BanknoteOverlayPainter(
                    detections: testDetections,
                    imageWidth: 720,
                    imageHeight: 1280,
                  ),
                ),
              ),

              // Top Bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Icon(Icons.flash_off_rounded, color: Colors.white, size: 22),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(radius: 4, backgroundColor: Color(0xFF00E676)),
                              SizedBox(width: 8),
                              Text(
                                'DETECTED (3)',
                                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Icon(Icons.volume_up_rounded, color: Colors.white, size: 22),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Floating Breakdown Banner & Grand Total
              Positioned(
                top: 110,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.70),
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
                          SizedBox(height: 3),
                          Text(
                            '3 items in direct view',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                        ),
                        child: const Text(
                          '₹65',
                          style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom Controls
              Positioned(
                bottom: 24,
                left: 20,
                right: 20,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                            child: const Text('💵 Currency', style: TextStyle(color: Color(0xFF151515), fontSize: 13, fontWeight: FontWeight.bold)),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                            child: const Text('📄 Text OCR', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.15),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 2.5),
                      ),
                      child: Center(
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                          child: const Icon(Icons.camera_alt_rounded, color: Color(0xFF1E1E1E), size: 28),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    print('[SCREENSHOT TEST] UI DISPLAYED ON SCREEN. HOLDING FOR SCREENCAP FOR 25 SECONDS...');
    await tester.runAsync(() async {
      await Future.delayed(const Duration(seconds: 25));
    });
    print('[SCREENSHOT TEST] Screencap window closed.');
  });
}

