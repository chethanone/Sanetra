import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/main.dart';

void main() {
  testWidgets('VisionMission root app renders without legacy counter UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VisionAssistantApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);

    // Dispose and flush any initialization timers started by services.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 15));
  });
}
