import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vision_assistant/services/ocr/ocr_postprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_preprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_recognition.dart';
import 'package:vision_assistant/services/ocr/ocr_result.dart';
import 'package:vision_assistant/services/ocr/ocr_symbol_normalizer.dart';

OcrPolygon _rectPoly(double x1, double y1, double x2, double y2, {double score = 0.95, double angle = 0.0}) {
  return OcrPolygon(
    topLeft: OcrPoint(x1, y1),
    topRight: OcrPoint(x2, y1),
    bottomRight: OcrPoint(x2, y2),
    bottomLeft: OcrPoint(x1, y2),
    score: score,
    angleDegrees: angle,
  );
}

OcrPolygon _rotatedPoly(double cx, double cy, double w, double h, double angleDeg) {
  final rad = angleDeg * math.pi / 180.0;
  final cosT = math.cos(rad);
  final sinT = math.sin(rad);
  final hw = w / 2.0;
  final hh = h / 2.0;

  OcrPoint rotate(double dx, double dy) {
    return OcrPoint(cx + dx * cosT - dy * sinT, cy + dx * sinT + dy * cosT);
  }

  return OcrPolygon(
    topLeft: rotate(-hw, -hh),
    topRight: rotate(hw, -hh),
    bottomRight: rotate(hw, hh),
    bottomLeft: rotate(-hw, hh),
    score: 0.95,
    angleDegrees: angleDeg,
  );
}

OcrPolygon _docRotatedPoly(double docX, double docY, double w, double h, double angleDeg, {double imgW = 800, double imgH = 600}) {
  final rad = angleDeg * math.pi / 180.0;
  final cosT = math.cos(rad);
  final sinT = math.sin(rad);

  // Rotate document point (docX, docY) around image center into screen coordinates
  final cx = imgW / 2.0;
  final cy = imgH / 2.0;
  final dx = docX - cx;
  final dy = docY - cy;
  final sx = cx + dx * cosT - dy * sinT;
  final sy = cy + dx * sinT + dy * cosT;

  return _rotatedPoly(sx, sy, w, h, angleDeg);
}

void main() {
  group('Sanetra v3.0 OCR Mode: Section-First Line-by-Line Reading Order', () {
    test('1. Two side-by-side boxes are read completely box-by-box without line-to-line jumping', () {
      // Box 1 (Left): x=50..350, 3 lines (y=100, y=140, y=180)
      // Box 2 (Right): x=450..750, 3 lines (y=105, y=145, y=185)
      // Legacy code interleaved them: Left1 -> Right1 -> Left2 -> Right2 -> Left3 -> Right3
      // Upgraded code reads: Left1 -> Left2 -> Left3 -> Right1 -> Right2 -> Right3
      final items = [
        OcrLineResult(text: 'Box2-Line1', confidence: 0.95, polygon: _rectPoly(450, 105, 750, 135), lineIndex: 0),
        OcrLineResult(text: 'Box1-Line1', confidence: 0.95, polygon: _rectPoly(50, 100, 350, 130), lineIndex: 1),
        OcrLineResult(text: 'Box2-Line2', confidence: 0.95, polygon: _rectPoly(450, 145, 750, 175), lineIndex: 2),
        OcrLineResult(text: 'Box1-Line2', confidence: 0.95, polygon: _rectPoly(50, 140, 350, 170), lineIndex: 3),
        OcrLineResult(text: 'Box2-Line3', confidence: 0.95, polygon: _rectPoly(450, 185, 750, 215), lineIndex: 4),
        OcrLineResult(text: 'Box1-Line3', confidence: 0.95, polygon: _rectPoly(50, 180, 350, 210), lineIndex: 5),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 400,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      expect(texts, [
        'Box1-Line1',
        'Box1-Line2',
        'Box1-Line3',
        'Box2-Line1',
        'Box2-Line2',
        'Box2-Line3',
      ]);
    });

    test('2. 2x2 Grid of cards reads Top-Left -> Top-Right -> Bottom-Left -> Bottom-Right', () {
      // Card A (Top-Left): x=50..300, y=50..120 (2 lines)
      // Card B (Top-Right): x=400..650, y=50..120 (2 lines)
      // Card C (Bottom-Left): x=50..300, y=200..270 (2 lines)
      // Card D (Bottom-Right): x=400..650, y=200..270 (2 lines)
      final items = [
        OcrLineResult(text: 'D-L1', confidence: 0.9, polygon: _rectPoly(400, 200, 650, 225), lineIndex: 0),
        OcrLineResult(text: 'A-L1', confidence: 0.9, polygon: _rectPoly(50, 50, 300, 75), lineIndex: 1),
        OcrLineResult(text: 'B-L1', confidence: 0.9, polygon: _rectPoly(400, 50, 650, 75), lineIndex: 2),
        OcrLineResult(text: 'C-L1', confidence: 0.9, polygon: _rectPoly(50, 200, 300, 225), lineIndex: 3),
        OcrLineResult(text: 'A-L2', confidence: 0.9, polygon: _rectPoly(50, 85, 300, 110), lineIndex: 4),
        OcrLineResult(text: 'B-L2', confidence: 0.9, polygon: _rectPoly(400, 85, 650, 110), lineIndex: 5),
        OcrLineResult(text: 'C-L2', confidence: 0.9, polygon: _rectPoly(50, 235, 300, 260), lineIndex: 6),
        OcrLineResult(text: 'D-L2', confidence: 0.9, polygon: _rectPoly(400, 235, 650, 260), lineIndex: 7),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 700,
        imageHeight: 350,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      expect(texts, [
        'A-L1',
        'A-L2',
        'B-L1',
        'B-L2',
        'C-L1',
        'C-L2',
        'D-L1',
        'D-L2',
      ]);
    });

    test('3. Spanning Header followed by two columns reads Header -> Column1 -> Column2', () {
      final items = [
        OcrLineResult(text: 'Col2-Line1', confidence: 0.95, polygon: _rectPoly(450, 160, 750, 190), lineIndex: 0),
        OcrLineResult(text: 'Main Spanning Document Title', confidence: 0.98, polygon: _rectPoly(60, 40, 740, 110), lineIndex: 1),
        OcrLineResult(text: 'Col1-Line1', confidence: 0.95, polygon: _rectPoly(50, 160, 350, 190), lineIndex: 2),
        OcrLineResult(text: 'Col2-Line2', confidence: 0.95, polygon: _rectPoly(450, 210, 750, 240), lineIndex: 3),
        OcrLineResult(text: 'Col1-Line2', confidence: 0.95, polygon: _rectPoly(50, 210, 350, 240), lineIndex: 4),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 300,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      expect(texts, [
        'Main Spanning Document Title',
        'Col1-Line1',
        'Col1-Line2',
        'Col2-Line1',
        'Col2-Line2',
      ]);
    });

    test('4. Rotated Document (30 deg tilt) maintains proper section-first reading order', () {
      // In document coordinates: Col 1 is on the left (x=150), Col 2 is on the right (x=450)
      // Line 1 is at y=100, Line 2 is at y=160.
      // Both columns are tilted by 30 degrees in the captured image.
      final items = [
        OcrLineResult(text: 'RotCol2-L1', confidence: 0.95, polygon: _docRotatedPoly(450, 100, 200, 30, 30.0), lineIndex: 0),
        OcrLineResult(text: 'RotCol1-L1', confidence: 0.95, polygon: _docRotatedPoly(150, 100, 200, 30, 30.0), lineIndex: 1),
        OcrLineResult(text: 'RotCol2-L2', confidence: 0.95, polygon: _docRotatedPoly(450, 160, 200, 30, 30.0), lineIndex: 2),
        OcrLineResult(text: 'RotCol1-L2', confidence: 0.95, polygon: _docRotatedPoly(150, 160, 200, 30, 30.0), lineIndex: 3),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 600,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      expect(texts, [
        'RotCol1-L1',
        'RotCol1-L2',
        'RotCol2-L1',
        'RotCol2-L2',
      ]);
    });

    test('4b. Inverted 180-deg Document reads top-to-bottom and section-wise (never bottom-up or reverse)', () {
      // Document is held upside down (180 deg).
      // In document coordinates:
      // Col 1 is on the left (docX=150), Col 2 is on the right (docX=450).
      // Line 1 is at docY=100, Line 2 is at docY=180.
      // When rotated 180 deg into an 800x600 image:
      // Line 1 is at screen Y=500 (bottom of screen), Line 2 is at screen Y=420 (higher up on screen).
      // Col 1 is at screen X=650 (right of screen), Col 2 is at screen X=350 (left of screen).
      final items = [
        OcrLineResult(text: 'InvCol2-L2', confidence: 0.95, orientationDegrees: 180, polygon: _docRotatedPoly(450, 180, 200, 30, 180.0), lineIndex: 0),
        OcrLineResult(text: 'InvCol1-L1', confidence: 0.95, orientationDegrees: 180, polygon: _docRotatedPoly(150, 100, 200, 30, 180.0), lineIndex: 1),
        OcrLineResult(text: 'InvCol2-L1', confidence: 0.95, orientationDegrees: 180, polygon: _docRotatedPoly(450, 100, 200, 30, 180.0), lineIndex: 2),
        OcrLineResult(text: 'InvCol1-L2', confidence: 0.95, orientationDegrees: 180, polygon: _docRotatedPoly(150, 180, 200, 30, 180.0), lineIndex: 3),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 600,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      // Must read Column 1 Line 1 -> Col 1 Line 2 -> Column 2 Line 1 -> Col 2 Line 2
      // Top-to-bottom of the inverted document, section-first, never bottom-up!
      expect(texts, [
        'InvCol1-L1',
        'InvCol1-L2',
        'InvCol2-L1',
        'InvCol2-L2',
      ]);
    });

    test('4c. 90-degree rotated Document (Portrait held sideways) reads top-to-bottom and section-wise', () {
      final items = [
        OcrLineResult(text: 'Rot90Col2-L2', confidence: 0.95, orientationDegrees: 90, polygon: _docRotatedPoly(450, 180, 200, 30, 90.0), lineIndex: 0),
        OcrLineResult(text: 'Rot90Col1-L1', confidence: 0.95, orientationDegrees: 90, polygon: _docRotatedPoly(150, 100, 200, 30, 90.0), lineIndex: 1),
        OcrLineResult(text: 'Rot90Col2-L1', confidence: 0.95, orientationDegrees: 90, polygon: _docRotatedPoly(450, 100, 200, 30, 90.0), lineIndex: 2),
        OcrLineResult(text: 'Rot90Col1-L2', confidence: 0.95, orientationDegrees: 90, polygon: _docRotatedPoly(150, 180, 200, 30, 90.0), lineIndex: 3),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 600,
      );

      final texts = analyzed.lines.map((l) => l.text).toList();
      expect(texts, [
        'Rot90Col1-L1',
        'Rot90Col1-L2',
        'Rot90Col2-L1',
        'Rot90Col2-L2',
      ]);
    });

    test('4d. Curved text unwrapping samples forward along text line without reverse flipping', () {
      final testImg = img.Image(width: 400, height: 400, numChannels: 3);
      img.fill(testImg, color: img.ColorRgb8(255, 255, 255));

      final curvePoly = OcrPolygon(
        topLeft: const OcrPoint(90, 180),
        topRight: const OcrPoint(310, 180),
        bottomRight: const OcrPoint(310, 220),
        bottomLeft: const OcrPoint(90, 220),
        score: 0.96,
        geometryType: 'curved',
        curveHalfHeight: 18.0,
        centerline: const [
          OcrPoint(100, 200),
          OcrPoint(150, 185),
          OcrPoint(200, 180),
          OcrPoint(250, 185),
          OcrPoint(300, 200),
        ],
      );

      final unwrap = OcrPostprocessing.extractRegionCrop(
        originalImage: testImg,
        polygon: curvePoly,
      );

      expect(unwrap, isNotNull);
      expect(unwrap!.width, greaterThan(150));
      expect(unwrap.height, closeTo(36, 6));
    });
  });

  group('Sanetra v3.0 OCR Mode: Handwriting Recognition Enhancements', () {
    test('5. Dynamic local contrast stretching recovers faint handwriting strokes', () {
      // Create a faint pencil/ink line on off-white paper
      // Background: rgb(240, 238, 230), faint strokes: rgb(215, 210, 200) -> range only 25
      final faintCrop = img.Image(width: 80, height: 30, numChannels: 3);
      img.fill(faintCrop, color: img.ColorRgb8(240, 238, 230));

      for (int x = 10; x < 70; x++) {
        faintCrop.setPixelRgb(x, 15, 215, 210, 200);
      }

      final enhanced = OcrPreprocessing.enhanceCropForHandwriting(faintCrop);
      expect(enhanced.width, 80);
      expect(enhanced.height, 30);

      // Enhanced ink pixels should have significantly lower luminance than background
      final bgPx = enhanced.getPixel(5, 5);
      final inkPx = enhanced.getPixel(40, 15);
      final bgLuma = 0.299 * bgPx.r + 0.587 * bgPx.g + 0.114 * bgPx.b;
      final inkLuma = 0.299 * inkPx.r + 0.587 * inkPx.g + 0.114 * inkPx.b;

      // The contrast difference should be expanded significantly
      expect(bgLuma - inkLuma, greaterThan(40.0));
    });

    test('6. Slant angle compensation de-slants cursive handwriting', () {
      // Create a slanted vertical stroke (sheared by 15 deg)
      final slantedCrop = img.Image(width: 60, height: 40, numChannels: 3);
      img.fill(slantedCrop, color: img.ColorRgb8(255, 255, 255));

      const double slantRad = 15.0 * math.pi / 180.0;
      final tanA = math.tan(slantRad);

      for (int y = 5; y < 35; y++) {
        final shift = ((y - 20) * tanA).round();
        for (int dx = -2; dx <= 2; dx++) {
          final x = 30 + shift + dx;
          if (x >= 0 && x < 60) {
            slantedCrop.setPixelRgb(x, y, 10, 10, 10);
          }
        }
      }

      final deslanted = OcrPreprocessing.deSlantCrop(slantedCrop);
      expect(deslanted.width, 60);
      expect(deslanted.height, 40);

      // The middle row should have ink centered near x=30
      final midPx = deslanted.getPixel(30, 20);
      expect(midPx.r, lessThan(80));
    });

    test('6b. Kannada Handwriting local adaptive enhancement reinforces delicate strokes without shear', () {
      final faintKannadaCrop = img.Image(width: 100, height: 40, numChannels: 3);
      img.fill(faintKannadaCrop, color: img.ColorRgb8(245, 242, 235));

      // Simulate a faint circular loop (Kannada letter "ರ" or "ಮ") and a delicate subscript Ottakshara stroke
      for (double rad = 0; rad < 2 * math.pi; rad += 0.1) {
        final cx = (35 + 10 * math.cos(rad)).round();
        final cy = (18 + 10 * math.sin(rad)).round();
        if (cx >= 0 && cx < 100 && cy >= 0 && cy < 40) {
          faintKannadaCrop.setPixelRgb(cx, cy, 210, 205, 195); // faint pen stroke
        }
      }
      // Faint subscript stroke below baseline (y = 32..36)
      for (int x = 32; x <= 40; x++) {
        faintKannadaCrop.setPixelRgb(x, 34, 215, 210, 200);
      }

      final enhanced = OcrPreprocessing.enhanceCropForKannadaHandwriting(faintKannadaCrop);
      expect(enhanced.width, 100);
      expect(enhanced.height, 40);

      // Ink core should be significantly darkened and reinforced
      final strokePx = enhanced.getPixel(35, 8); // top of circular loop
      final bgPx = enhanced.getPixel(10, 10);
      final bgLuma = 0.299 * bgPx.r + 0.587 * bgPx.g + 0.114 * bgPx.b;
      final strokeLuma = 0.299 * strokePx.r + 0.587 * strokePx.g + 0.114 * strokePx.b;

      expect(bgLuma - strokeLuma, greaterThan(45.0));

      // Subscript stroke should also be preserved and reinforced
      final subPx = enhanced.getPixel(36, 34);
      final subLuma = 0.299 * subPx.r + 0.587 * subPx.g + 0.114 * subPx.b;
      expect(bgLuma - subLuma, greaterThan(35.0));
    });

    test('6c. Kannada Unicode normalizer cleans CTC combining marks and duplicate viramas', () {
      // 1. Duplicate viramas (Halants): e.g. ಕ್ಕ್ -> ಕ್
      const duplicateViramas = 'ಕ\u0CCD\u0CCDಕ';
      final cleanVirama = OcrRecognitionService.cleanKannadaUnicode(duplicateViramas);
      expect(cleanVirama, 'ಕ್ಕ');

      // 2. Orphaned combining marks at start of word: e.g. " ಾಗಳು" -> "ಗಳು"
      const orphanedMatra = ' ಾಗಳು';
      final cleanMatra = OcrRecognitionService.cleanKannadaUnicode(orphanedMatra);
      expect(cleanMatra, 'ಗಳು');

      // 3. Normal multi-word Kannada text with spaces is preserved
      const validPhrase = 'ನಮಸ್ಕಾರ  ಕರ್ನಾಟಕ';
      final cleanPhrase = OcrRecognitionService.cleanKannadaUnicode(validPhrase);
      expect(cleanPhrase, 'ನಮಸ್ಕಾರ ಕರ್ನಾಟಕ');
    });
  });

  group('Sanetra v3.0 OCR Mode: Multilingual Section Division (English, Hindi, Kannada)', () {
    test('7. Multi-language text line is partitioned into clean speech segments', () {
      final line = OcrLineResult(
        text: 'Aspirin 75 mg ಮಾತ್ರೆಗಳು गोली',
        confidence: 0.94,
        polygon: _rectPoly(50, 50, 450, 90),
        lineIndex: 1,
        language: 'kn-IN',
        segments: const [
          OcrTextSegment(text: 'Aspirin 75 mg', language: 'en-IN', confidence: 0.96),
          OcrTextSegment(text: 'ಮಾತ್ರೆಗಳು', language: 'kn-IN', confidence: 0.94),
          OcrTextSegment(text: 'गोली', language: 'hi-IN', confidence: 0.92),
        ],
      );

      final analyzed = OcrPostprocessing.sortReadingOrder([line]);
      expect(analyzed.length, 1);
      final res = analyzed.first;
      expect(res.segments.length, 3);
      expect(res.segments[0].language, 'en-IN');
      expect(res.segments[0].text, 'Aspirin 75 mg');
      expect(res.segments[1].language, 'kn-IN');
      expect(res.segments[1].text, 'ಮಾತ್ರೆಗಳು');
      expect(res.segments[2].language, 'hi-IN');
      expect(res.segments[2].text, 'गोली');
    });
  });

  group('Sanetra v3.0 OCR Mode: Currency, Math & Packaging Symbol Recognition & Speech', () {
    test('8. Symbol validator recognizes currency, math, units, and packaging symbols', () {
      final symbols = ['₹', '\$', '€', '£', '¥', '¢', '₿', '₽', '%', '+', '-', '±', '×', '÷', '=', '<', '>', '°', '℃', '℉', 'µ', 'Ω', '∆', '№', '&', '@', '✓', '✔', '✗', '✘', '©', '®', '™', '℞'];
      for (final sym in symbols) {
        final rune = sym.runes.first;
        expect(OcrSymbolNormalizer.isSymbolRune(rune), isTrue, reason: 'Symbol $sym should be recognized as a valid symbol rune');
      }
    });

    test('9. English TTS expands currency, math, and everyday packaging symbols naturally', () {
      expect(OcrSymbolNormalizer.expandForSpeech('Price: ₹500', 'en-IN'), contains('500 Rupees'));
      expect(OcrSymbolNormalizer.expandForSpeech('Total: \$120.50', 'en-IN'), contains('120.50 Dollars'));
      expect(OcrSymbolNormalizer.expandForSpeech('Fee: €45', 'en-IN'), contains('45 Euros'));
      expect(OcrSymbolNormalizer.expandForSpeech('Cost: £20', 'en-IN'), contains('20 Pounds'));
      expect(OcrSymbolNormalizer.expandForSpeech('Price: ¥1000', 'en-IN'), contains('1000 Yen'));
      expect(OcrSymbolNormalizer.expandForSpeech('Discount: 25%', 'en-IN'), contains('25 percent'));
      expect(OcrSymbolNormalizer.expandForSpeech('Temp: 37°C', 'en-IN'), contains('37 degrees Celsius'));
      expect(OcrSymbolNormalizer.expandForSpeech('Batch № 402', 'en-IN'), contains('Number 402'));
      expect(OcrSymbolNormalizer.expandForSpeech('Item ℞ 10mg', 'en-IN'), contains('Prescription 10mg'));
      expect(OcrSymbolNormalizer.expandForSpeech('Status: ✓', 'en-IN'), contains('Checked'));
    });

    test('10. Hindi TTS expands currency, math, and everyday packaging symbols naturally', () {
      expect(OcrSymbolNormalizer.expandForSpeech('मूल्य: ₹500', 'hi-IN'), contains('500 रुपये'));
      expect(OcrSymbolNormalizer.expandForSpeech('मूल्य: \$50', 'hi-IN'), contains('50 डॉलर'));
      expect(OcrSymbolNormalizer.expandForSpeech('छूट: 20%', 'hi-IN'), contains('20 प्रतिशत'));
      expect(OcrSymbolNormalizer.expandForSpeech('तापमान: 37°C', 'hi-IN'), contains('37 डिग्री सेल्सियस'));
      expect(OcrSymbolNormalizer.expandForSpeech('बैच № 12', 'hi-IN'), contains('नंबर 12'));
      expect(OcrSymbolNormalizer.expandForSpeech('दवा ℞', 'hi-IN'), contains('प्रिस्क्रिप्शन'));
      expect(OcrSymbolNormalizer.expandForSpeech('स्थिति: ✓', 'hi-IN'), contains('सही'));
    });

    test('11. Kannada TTS expands currency, math, and everyday packaging symbols naturally', () {
      expect(OcrSymbolNormalizer.expandForSpeech('ಬೆಲೆ: ₹500', 'kn-IN'), contains('500 ರೂಪಾಯಿ'));
      expect(OcrSymbolNormalizer.expandForSpeech('ದರ: \$100', 'kn-IN'), contains('100 ಡಾಲರ್'));
      expect(OcrSymbolNormalizer.expandForSpeech('ರಿಯಾಯಿತಿ: 15%', 'kn-IN'), contains('15 ಪ್ರತಿಶತ'));
      expect(OcrSymbolNormalizer.expandForSpeech('ತಾಪಮಾನ: 38°C', 'kn-IN'), contains('38 ಡಿಗ್ರಿ ಸೆಲ್ಸಿಯಸ್'));
      expect(OcrSymbolNormalizer.expandForSpeech('ಕ್ರಮ № 5', 'kn-IN'), contains('ಸಂಖ್ಯೆ 5'));
      expect(OcrSymbolNormalizer.expandForSpeech('ಔಷಧಿ ℞', 'kn-IN'), contains('ವೈದ್ಯಕೀಯ ಚೀಟಿ'));
      expect(OcrSymbolNormalizer.expandForSpeech('ಸ್ಥಿತಿ: ✓', 'kn-IN'), contains('ಸರಿ'));
    });
  });
}
