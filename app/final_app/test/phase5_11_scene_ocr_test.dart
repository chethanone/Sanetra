import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vision_assistant/services/ocr/ocr_postprocessing.dart';
import 'package:vision_assistant/services/ocr/ocr_result.dart';

OcrPolygon _rectPoly(double x1, double y1, double x2, double y2, {double score = 0.95}) {
  return OcrPolygon(
    topLeft: OcrPoint(x1, y1),
    topRight: OcrPoint(x2, y1),
    bottomRight: OcrPoint(x2, y2),
    bottomLeft: OcrPoint(x1, y2),
    score: score,
  );
}

void main() {
  group('Phase 5.11 Curved-Text Extraction & Rectification', () {
    test('detects curved probability component and unwraps along centerline', () {
      const w = 160;
      const h = 96;
      final predMap = Float32List(w * h);

      // Draw a curved arc band (y = 55 - 24 * sin(pi * (x - 20) / 120))
      for (int x = 20; x < 140; x++) {
        final t = (x - 20) / 120.0;
        final cy = 58.0 - 24.0 * (1.0 - (2.0 * t - 1.0) * (2.0 * t - 1.0));
        for (int dy = -5; dy <= 5; dy++) {
          final y = (cy + dy).round().clamp(0, h - 1);
          predMap[y * w + x] = 0.92;
        }
      }

      final polys = OcrPostprocessing.extractTextPolygons(
        predMap: predMap,
        targetWidth: w,
        targetHeight: h,
        scaleX: 2.0,
        scaleY: 2.0,
        origWidth: w * 2,
        origHeight: h * 2,
      );

      expect(polys.length, 1);
      final p = polys.first;
      expect(p.geometryType, 'curved');
      expect(p.isCurved, isTrue);
      expect(p.centerline.length, greaterThanOrEqualTo(4));

      // Draw a matching white canvas with a dark curved stripe and verify unwrapping
      final canvas = img.Image(width: w * 2, height: h * 2, numChannels: 3);
      img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
      for (int x = 40; x < 280; x++) {
        final t = (x - 40) / 240.0;
        final cy = 116.0 - 48.0 * (1.0 - (2.0 * t - 1.0) * (2.0 * t - 1.0));
        for (int dy = -3; dy <= 3; dy++) {
          canvas.setPixelRgb(x, (cy + dy).round(), 10, 10, 10);
        }
      }

      final unwrapped = OcrPostprocessing.extractRegionCrop(
        originalImage: canvas,
        polygon: p,
        allowAutoVerticalRotate: false,
      );
      expect(unwrapped, isNotNull);
      expect(unwrapped!.width, greaterThan(unwrapped.height));

      // Center row of unwrapped strip should contain dark ink across the width
      final midY = unwrapped.height ~/ 2;
      int darkSamples = 0;
      for (int x = 10; x < unwrapped.width - 10; x += 4) {
        final px = unwrapped.getPixel(x, midY);
        if (px.r < 120) darkSamples++;
      }
      expect(darkSamples, greaterThan(5));
    });

    test('preserves vertical crop orientation when allowAutoVerticalRotate is false', () {
      final canvas = img.Image(width: 200, height: 300, numChannels: 3);
      img.fill(canvas, color: img.ColorRgb8(240, 240, 240));
      final poly = _rectPoly(60, 20, 110, 260);

      final rawVertical = OcrPostprocessing.extractRegionCrop(
        originalImage: canvas,
        polygon: poly,
        allowAutoVerticalRotate: false,
      );
      expect(rawVertical, isNotNull);
      expect(rawVertical!.height, greaterThan(rawVertical.width));

      final autoRotated = OcrPostprocessing.extractPerspectiveCrop(
        originalImage: canvas,
        polygon: poly,
      );
      expect(autoRotated, isNotNull);
      expect(autoRotated!.width, greaterThan(autoRotated.height));
    });
  });

  group('Phase 5.11 Intelligent Reading Order & Spatial Guidance', () {
    test('reads two-column documents column-by-column without interleaving', () {
      final items = [
        OcrLineResult(text: 'Col2-Line1', confidence: 0.95, polygon: _rectPoly(540, 50, 920, 90), lineIndex: 0),
        OcrLineResult(text: 'Col1-Line1', confidence: 0.95, polygon: _rectPoly(40, 50, 420, 90), lineIndex: 1),
        OcrLineResult(text: 'Col2-Line2', confidence: 0.95, polygon: _rectPoly(540, 120, 920, 160), lineIndex: 2),
        OcrLineResult(text: 'Col1-Line2', confidence: 0.95, polygon: _rectPoly(40, 120, 420, 160), lineIndex: 3),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 1000,
        imageHeight: 600,
      );

      expect(analyzed.lines.map((e) => e.text).toList(), [
        'Col1-Line1',
        'Col1-Line2',
        'Col2-Line1',
        'Col2-Line2',
      ]);
      expect(analyzed.lines[0].columnIndex, 0);
      expect(analyzed.lines[2].columnIndex, 1);
      expect(analyzed.sceneSummary, contains('2-column'));
    });

    test('prioritizes prominent signboard heading before smaller subtext', () {
      final items = [
        OcrLineResult(text: 'Ph: 080-123456', confidence: 0.90, polygon: _rectPoly(120, 60, 480, 96), lineIndex: 0),
        OcrLineResult(text: 'ನಾಗಕೃಪ ಮೆಡಿಕಲ್ಸ್', confidence: 0.94, polygon: _rectPoly(100, 140, 860, 260), lineIndex: 1, language: 'kn-IN'),
        OcrLineResult(text: '24 Hours Open', confidence: 0.92, polygon: _rectPoly(200, 300, 620, 336), lineIndex: 2),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 1000,
        imageHeight: 500,
      );

      expect(analyzed.lines.first.text, 'ನಾಗಕೃಪ ಮೆಡಿಕಲ್ಸ್');
      expect(analyzed.lines.first.isHeading, isTrue);
      expect(analyzed.sceneSummary, contains('Signboard heading first'));
    });

    test('suppresses heavily overlapping duplicate detections', () {
      final items = [
        OcrLineResult(text: 'Paracetamol', confidence: 0.94, polygon: _rectPoly(100, 100, 400, 160), lineIndex: 0),
        OcrLineResult(text: 'Paracetamo', confidence: 0.72, polygon: _rectPoly(105, 102, 395, 158), lineIndex: 1),
        OcrLineResult(text: '500 mg', confidence: 0.91, polygon: _rectPoly(100, 200, 280, 250), lineIndex: 2),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        items,
        imageWidth: 800,
        imageHeight: 600,
      );

      expect(analyzed.lines.length, 2);
      expect(analyzed.lines.map((e) => e.text).toList(), ['Paracetamol', '500 mg']);
    });

    test('provides accurate spatial guidance when text is off-center or near edge', () {
      final leftEdgeItems = [
        OcrLineResult(text: 'Exit', confidence: 0.95, polygon: _rectPoly(5, 250, 180, 310), lineIndex: 0),
      ];

      final analyzed = OcrPostprocessing.analyzeSceneAndOrder(
        leftEdgeItems,
        imageWidth: 1000,
        imageHeight: 600,
      );

      expect(analyzed.lines.first.spatialPosition, 'left');
      expect(analyzed.sceneSummary, contains('Text is on the left.'));
      expect(analyzed.sceneSummary, contains('Move back slightly if edges are cut off.'));
    });
  });
}
