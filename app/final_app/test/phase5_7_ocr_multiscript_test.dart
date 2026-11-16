import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vision_assistant/services/ocr/ocr_postprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_recognition.dart';
import 'package:vision_assistant/services/ocr/ocr_result.dart';

void main() {
  group('Phase 5.7 Mixed-Script Region Segmentation', () {
    test('extractWordChunks preserves intra-word combining gaps and splits at spaces', () {
      // White background 200x40 with two words:
      // Word 1: x=10..55 (with a 2px intra-glyph gap at x=30..31 that must NOT split)
      // Space gap: x=56..75 (20px >= max(4, 0.18*40)=7px -> MUST split)
      // Word 2: x=76..140
      final crop = img.Image(width: 200, height: 40);
      img.fill(crop, color: img.ColorRgb8(255, 255, 255));
      for (int y = 8; y < 32; y++) {
        for (int x = 10; x <= 29; x++) {
          crop.setPixelRgb(x, y, 10, 10, 10);
        }
        for (int x = 32; x <= 55; x++) {
          crop.setPixelRgb(x, y, 10, 10, 10);
        }
        for (int x = 76; x <= 140; x++) {
          crop.setPixelRgb(x, y, 10, 10, 10);
        }
      }

      final chunks = OcrRecognitionService.extractWordChunks(crop);
      expect(chunks.length, equals(2));
      expect(chunks[0].startX, equals(10));
      expect(chunks[0].endX, equals(55));
      expect(chunks[1].startX, equals(76));
      expect(chunks[1].endX, equals(140));
    });

    test('mergeAdjacentSegments merges same-language runs and preserves tri-script order', () {
      final merged = OcrRecognitionService.mergeAdjacentSegments(const [
        OcrTextSegment(text: 'Paracetamol', language: 'en-IN', confidence: 0.98),
        OcrTextSegment(text: '500 mg', language: 'en-IN', confidence: 0.96),
        OcrTextSegment(text: 'ದಿನಕ್ಕೆ', language: 'kn-IN', confidence: 0.95),
        OcrTextSegment(text: 'ಎರಡು ಬಾರಿ', language: 'kn-IN', confidence: 0.93),
        OcrTextSegment(text: 'भोजन के बाद', language: 'hi-IN', confidence: 0.94),
      ]);

      expect(merged.length, equals(3));
      expect(merged[0].language, equals('en-IN'));
      expect(merged[0].text, equals('Paracetamol 500 mg'));
      expect(merged[1].language, equals('kn-IN'));
      expect(merged[1].text, equals('ದಿನಕ್ಕೆ ಎರಡು ಬಾರಿ'));
      expect(merged[2].language, equals('hi-IN'));
      expect(merged[2].text, equals('भोजन के बाद'));
    });

    test('sortReadingOrder preserves line segments and language metadata', () {
      const line = OcrLineResult(
        text: 'Paracetamol 500 mg ದಿನಕ್ಕೆ ಎರಡು ಬಾರಿ',
        confidence: 0.95,
        polygon: OcrPolygon(
          topLeft: OcrPoint(10, 20),
          topRight: OcrPoint(400, 20),
          bottomRight: OcrPoint(400, 60),
          bottomLeft: OcrPoint(10, 60),
          score: 0.95,
        ),
        lineIndex: 1,
        language: 'kn-IN',
        segments: [
          OcrTextSegment(
            text: 'Paracetamol 500 mg',
            language: 'en-IN',
            confidence: 0.97,
          ),
          OcrTextSegment(
            text: 'ದಿನಕ್ಕೆ ಎರಡು ಬಾರಿ',
            language: 'kn-IN',
            confidence: 0.93,
          ),
        ],
      );

      final ordered = OcrPostprocessing.sortReadingOrder([line]);
      expect(ordered.length, equals(1));
      expect(ordered.first.language, equals('kn-IN'));
      expect(ordered.first.segments.length, equals(2));
      expect(ordered.first.segments[0].language, equals('en-IN'));
      expect(ordered.first.segments[1].language, equals('kn-IN'));
    });
  });
}
