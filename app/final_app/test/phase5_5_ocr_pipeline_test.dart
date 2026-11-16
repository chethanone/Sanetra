import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vision_assistant/services/ocr/ocr_postprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_preprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_result.dart';

OcrPolygon _box(double x1, double y1, double x2, double y2) => OcrPolygon(
      topLeft: OcrPoint(x1, y1),
      topRight: OcrPoint(x2, y1),
      bottomRight: OcrPoint(x2, y2),
      bottomLeft: OcrPoint(x1, y2),
      score: 0.95,
    );

void main() {
  group('Phase 5.5 OCR pipeline fixes', () {
    test('sortReadingOrder preserves per-line language and uncertainty', () {
      final items = [
        OcrLineResult(
          text: 'ಕನ್ನಡ ಸಾಲು',
          confidence: 0.91,
          polygon: _box(20, 120, 220, 150),
          lineIndex: 0,
          language: 'kn-IN',
          isLanguageUncertain: false,
        ),
        OcrLineResult(
          text: 'Hello World',
          confidence: 0.96,
          polygon: _box(20, 20, 200, 50),
          lineIndex: 1,
          language: 'en-IN',
          isLanguageUncertain: false,
        ),
        OcrLineResult(
          text: 'हिन्दी पाठ',
          confidence: 0.84,
          polygon: _box(20, 220, 210, 250),
          lineIndex: 2,
          language: 'hi-IN',
          isLanguageUncertain: true,
        ),
      ];

      final ordered = OcrPostprocessing.sortReadingOrder(items);
      expect(ordered.length, 3);
      expect(ordered[0].text, 'Hello World');
      expect(ordered[0].language, 'en-IN');
      expect(ordered[0].lineIndex, 1);

      expect(ordered[1].text, 'ಕನ್ನಡ ಸಾಲು');
      expect(ordered[1].language, 'kn-IN');
      expect(ordered[1].isLanguageUncertain, isFalse);
      expect(ordered[1].lineIndex, 2);

      expect(ordered[2].text, 'हिन्दी पाठ');
      expect(ordered[2].language, 'hi-IN');
      expect(ordered[2].isLanguageUncertain, isTrue);
      expect(ordered[2].lineIndex, 3);
    });

    test('sortReadingOrder separates heading and nearby small body lines', () {
      // Large heading (height 80, centerY 50), followed by small body line (height 16, centerY 105).
      // Previously avgHeight*0.70 could merge lines with disparate heights; local height keeps them separate.
      final items = [
        OcrLineResult(
          text: 'HEADING',
          confidence: 0.98,
          polygon: _box(10, 10, 300, 90),
          lineIndex: 0,
          language: 'en-IN',
        ),
        OcrLineResult(
          text: 'right',
          confidence: 0.92,
          polygon: _box(150, 97, 250, 113),
          lineIndex: 1,
          language: 'en-IN',
        ),
        OcrLineResult(
          text: 'left',
          confidence: 0.94,
          polygon: _box(10, 97, 90, 113),
          lineIndex: 2,
          language: 'en-IN',
        ),
      ];

      final ordered = OcrPostprocessing.sortReadingOrder(items);
      expect(ordered.map((e) => e.text).toList(), ['HEADING', 'left', 'right']);
    });

    test('prepareRecognitionTensor adds replicate horizontal padding cleanly', () {
      final im = img.Image(width: 40, height: 24, numChannels: 3);
      for (int y = 0; y < 24; y++) {
        for (int x = 0; x < 40; x++) {
          im.setPixelRgb(x, y, 255, 0, 0); // pure red in RGB -> B=0, G=0, R=255
        }
      }
      final prep = OcrPreprocessing.prepareRecognitionTensor(im, padLr: 4);
      expect(prep.targetHeight, 48);
      // (40 + 8) * 48 / 24 = 96, padded to baseWidth 320
      expect(prep.targetWidth, 96);
      expect(prep.tensorWidth, 320);
      expect(prep.tensorData.length, 3 * 48 * 320);
      // Channel 0 (B) should be -1.0, Channel 2 (R) should be +1.0 inside [0..95]
      expect(prep.tensorData[0], closeTo(-1.0, 1e-4));
      final planeSize = 48 * 320;
      expect(prep.tensorData[2 * planeSize], closeTo(1.0, 1e-4));
    });
  });
}
