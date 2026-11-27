import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Holds preprocessed tensor data and geometry mapping for detector.
class DetectionPreprocessResult {
  final Float32List tensorData;
  final int targetWidth;
  final int targetHeight;
  final double scaleX;
  final double scaleY;
  final int originalWidth;
  final int originalHeight;

  const DetectionPreprocessResult({
    required this.tensorData,
    required this.targetWidth,
    required this.targetHeight,
    required this.scaleX,
    required this.scaleY,
    required this.originalWidth,
    required this.originalHeight,
  });
}

/// Holds preprocessed tensor data for recognizer.
class RecognitionPreprocessResult {
  final Float32List tensorData;
  final int targetWidth;
  final int tensorWidth;
  final int targetHeight;

  const RecognitionPreprocessResult({
    required this.tensorData,
    required this.targetWidth,
    required this.tensorWidth,
    required this.targetHeight,
  });
}

class OcrPreprocessing {
  // PP-OCRv5 Mobile Detection Preprocessing Constants
  static const int detMaxLongSide = 960;
  static const List<double> detMean = [0.485, 0.456, 0.406];
  static const List<double> detStd = [0.229, 0.224, 0.225];

  // PP-OCRv5 Mobile Recognition Preprocessing Constants
  static const int recHeight = 48;
  static const int recBaseWidth = 320;
  static const int recMaxWidth = 3200;

  /// Preprocess an image for the DBNet text detector.
  ///
  /// Resizes image preserving aspect ratio with max long side 960,
  /// rounded to multiples of 32 (min 32).
  /// Normalizes to BGR NCHW layout using ImageNet mean/std.
  static DetectionPreprocessResult prepareDetectionTensor(img.Image originalImage) {
    final origW = originalImage.width;
    final origH = originalImage.height;

    final maxSide = math.max(origW, origH);
    final double scale = detMaxLongSide / maxSide.toDouble();

    // Round target dimensions to nearest multiples of 32
    int targetW = ((origW * scale) / 32).round() * 32;
    int targetH = ((origH * scale) / 32).round() * 32;

    targetW = math.max(32, targetW);
    targetH = math.max(32, targetH);

    final resizedImage = img.copyResize(
      originalImage,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.linear,
    );

    final planeSize = targetW * targetH;
    final tensorData = Float32List(3 * planeSize);

    // Channel order in NCHW is BGR:
    // Plane 0: Blue (mean 0.485, std 0.229)
    // Plane 1: Green (mean 0.456, std 0.224)
    // Plane 2: Red (mean 0.406, std 0.225)
    for (int y = 0; y < targetH; y++) {
      for (int x = 0; x < targetW; x++) {
        final pixel = resizedImage.getPixel(x, y);
        final idx = y * targetW + x;

        tensorData[idx] = (pixel.b / 255.0 - detMean[0]) / detStd[0];
        tensorData[planeSize + idx] = (pixel.g / 255.0 - detMean[1]) / detStd[1];
        tensorData[2 * planeSize + idx] = (pixel.r / 255.0 - detMean[2]) / detStd[2];
      }
    }

    final scaleX = origW / targetW.toDouble();
    final scaleY = origH / targetH.toDouble();

    return DetectionPreprocessResult(
      tensorData: tensorData,
      targetWidth: targetW,
      targetHeight: targetH,
      scaleX: scaleX,
      scaleY: scaleY,
      originalWidth: origW,
      originalHeight: origH,
    );
  }

  /// Preprocess a cropped text image for the PP-OCRv5 recognizer.
  ///
  /// Adds a small horizontal edge-replicate border ([padLr]) to prevent
  /// leading/trailing character clipping, resizes crop to height 48,
  /// target dynamic width W = round(rw * 48 / rh) clamped between 32 and 3200,
  /// pads with zeros to recBaseWidth (320) if target width is less than 320,
  /// and normalizes to BGR NCHW layout using (pixel / 255.0 - 0.5) / 0.5.
  static RecognitionPreprocessResult prepareRecognitionTensor(
    img.Image cropImage, {
    bool padToBaseWidth = true,
    int padLr = 4,
  }) {
    img.Image source = cropImage;
    if (padLr > 0 && cropImage.width > 0 && cropImage.height > 0) {
      final paddedW = cropImage.width + 2 * padLr;
      final padded = img.Image(
        width: paddedW,
        height: cropImage.height,
        numChannels: cropImage.numChannels,
      );
      for (int y = 0; y < cropImage.height; y++) {
        final leftPx = cropImage.getPixel(0, y);
        final rightPx = cropImage.getPixel(cropImage.width - 1, y);
        for (int x = 0; x < padLr; x++) {
          padded.setPixel(x, y, leftPx);
          padded.setPixel(padLr + cropImage.width + x, y, rightPx);
        }
        for (int x = 0; x < cropImage.width; x++) {
          padded.setPixel(padLr + x, y, cropImage.getPixel(x, y));
        }
      }
      source = padded;
    }

    final cropW = source.width;
    final cropH = source.height;

    int targetW = (cropW * recHeight / cropH.toDouble()).round();
    targetW = targetW.clamp(32, recMaxWidth);

    final resizedCrop = img.copyResize(
      source,
      width: targetW,
      height: recHeight,
      interpolation: img.Interpolation.linear,
    );

    final int tensorW = (padToBaseWidth && targetW < recBaseWidth) ? recBaseWidth : targetW;
    final planeSize = recHeight * tensorW;
    final tensorData = Float32List(3 * planeSize);

    // Padding is 0.0 in float tensor (representing zero-pad)
    for (int y = 0; y < recHeight; y++) {
      for (int x = 0; x < targetW; x++) {
        final pixel = resizedCrop.getPixel(x, y);
        final idx = y * tensorW + x;

        // BGR layout, normalized via (p / 255 - 0.5) / 0.5
        tensorData[idx] = (pixel.b / 255.0 - 0.5) / 0.5;
        tensorData[planeSize + idx] = (pixel.g / 255.0 - 0.5) / 0.5;
        tensorData[2 * planeSize + idx] = (pixel.r / 255.0 - 0.5) / 0.5;
      }
    }

    return RecognitionPreprocessResult(
      tensorData: tensorData,
      targetWidth: targetW,
      tensorWidth: tensorW,
      targetHeight: recHeight,
    );
  }

  static const int arjunaRecHeight = 32;
  static const List<int> arjunaBuckets = <int>[
    64, 96, 128, 160, 192, 256, 320, 384, 512, 640, 800, 1024, 1280,
  ];

  /// Preprocess a cropped text image for the Arjuna Kannada/English SVTRv2
  /// recognizer (`kanen_rec_e5_int8.onnx`), matching `kanen_infer/rec_onnx.py`:
  /// height=32, grayscale replicated to 3 channels, `(gray/255 - 0.5)/0.5`,
  /// white-padded (+1.0) to the smallest width bucket >= `ceil(ratio * 32 / 4) * 4`.
  static RecognitionPreprocessResult prepareArjunaKannadaTensor(
    img.Image cropImage,
  ) {
    final int cropW = cropImage.width;
    final int cropH = cropImage.height;
    final double ratio = math.min(cropW / math.max(cropH, 1).toDouble(), 40.0);
    final int rawW = (ratio * arjunaRecHeight / 4.0).ceil() * 4;
    final int tensorW = arjunaBuckets.firstWhere(
      (b) => b >= rawW,
      orElse: () => arjunaBuckets.last,
    );
    final int nw = math.min(
      tensorW,
      math.max(8, (cropW * arjunaRecHeight / math.max(cropH, 1)).round()),
    );

    final resized = img.copyResize(
      cropImage,
      width: nw,
      height: arjunaRecHeight,
      interpolation: cropH > arjunaRecHeight
          ? img.Interpolation.average
          : img.Interpolation.cubic,
    );

    final int planeSize = arjunaRecHeight * tensorW;
    final tensorData = Float32List(3 * planeSize);
    tensorData.fillRange(0, tensorData.length, 1.0);

    for (int y = 0; y < arjunaRecHeight; y++) {
      for (int x = 0; x < nw; x++) {
        final px = resized.getPixel(x, y);
        final double gray =
            (0.299 * px.r + 0.587 * px.g + 0.114 * px.b) / 255.0;
        final double norm = (gray - 0.5) / 0.5;
        final int idx = y * tensorW + x;
        tensorData[idx] = norm;
        tensorData[planeSize + idx] = norm;
        tensorData[2 * planeSize + idx] = norm;
      }
    }

    return RecognitionPreprocessResult(
      tensorData: tensorData,
      targetWidth: nw,
      tensorWidth: tensorW,
      targetHeight: arjunaRecHeight,
    );
  }

  /// Enhances handwriting strokes by dynamic local contrast stretching,
  /// background leveling, and edge sharpening to rescue faint ballpoint, pencil,
  /// or colored ink strokes.
  static img.Image enhanceCropForHandwriting(img.Image crop) {
    if (crop.width < 6 || crop.height < 6) return crop;

    final w = crop.width;
    final h = crop.height;
    final lumas = <double>[];
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = crop.getPixel(x, y);
        lumas.add(0.299 * p.r + 0.587 * p.g + 0.114 * p.b);
      }
    }
    lumas.sort();

    // In thin handwriting, strokes occupy ~1% to 10% of pixels.
    // Use the 1st percentile as ink floor and 95th percentile as paper background ceiling.
    final double inkFloor = lumas[(lumas.length * 0.01).floor()];
    final double bgCeiling = lumas[(lumas.length * 0.95).floor()];
    final double range = math.max(15.0, bgCeiling - inkFloor);

    final enhanced = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = crop.getPixel(x, y);
        final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final normLuma = ((luma - inkFloor) / range).clamp(0.0, 1.0);
        // Gamma stretch to deepen ink valleys while leaving paper bright white
        final targetLuma = math.pow(normLuma, 1.25) * 255.0;
        final factor = luma > 0.0 ? targetLuma / luma : 1.0;
        final r = (p.r * factor).round().clamp(0, 255);
        final g = (p.g * factor).round().clamp(0, 255);
        final b = (p.b * factor).round().clamp(0, 255);
        enhanced.setPixelRgb(x, y, r, g, b);
      }
    }
    return enhanced;
  }

  /// Enhances Kannada handwriting strokes by tile-based adaptive local contrast
  /// stretching and morphological stroke reinforcement (min-filtering thin strokes)
  /// without applying destructive de-slanting to circular Kannada glyphs.
  static img.Image enhanceCropForKannadaHandwriting(img.Image crop) {
    if (crop.width < 8 || crop.height < 8) return crop;

    final w = crop.width;
    final h = crop.height;

    // 1. Tile-based local contrast stretching to normalize shadow gradients across the line
    final int tileSize = math.max(16, math.min(64, (w / 4).round()));
    final numTiles = (w / tileSize).ceil();
    final enhanced = img.Image(width: w, height: h, numChannels: 3);

    for (int t = 0; t < numTiles; t++) {
      final xStart = t * tileSize;
      final xEnd = math.min(w, (t + 1) * tileSize);
      final tileLumas = <double>[];

      for (int y = 0; y < h; y++) {
        for (int x = xStart; x < xEnd; x++) {
          final p = crop.getPixel(x, y);
          tileLumas.add(0.299 * p.r + 0.587 * p.g + 0.114 * p.b);
        }
      }
      if (tileLumas.isEmpty) continue;
      tileLumas.sort();

      // In thin handwriting, ink occupies 1% to 15% of pixels
      final double inkFloor = tileLumas[(tileLumas.length * 0.02).floor()];
      final double bgCeiling = tileLumas[(tileLumas.length * 0.93).floor()];
      final double rawDiff = bgCeiling - inkFloor;

      if (rawDiff < 14.0) {
        // Tile is pure paper background without ink strokes: keep bright white
        for (int y = 0; y < h; y++) {
          for (int x = xStart; x < xEnd; x++) {
            enhanced.setPixelRgb(x, y, 255, 255, 255);
          }
        }
        continue;
      }

      final double range = math.max(18.0, rawDiff);

      for (int y = 0; y < h; y++) {
        for (int x = xStart; x < xEnd; x++) {
          final p = crop.getPixel(x, y);
          final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          final normLuma = ((luma - inkFloor) / range).clamp(0.0, 1.0);
          // Gamma curve emphasizing faint pencil/ballpoint strokes
          final targetLuma = math.pow(normLuma, 1.35) * 255.0;
          final factor = luma > 0.0 ? targetLuma / luma : 1.0;
          final r = (p.r * factor).round().clamp(0, 255);
          final g = (p.g * factor).round().clamp(0, 255);
          final b = (p.b * factor).round().clamp(0, 255);
          enhanced.setPixelRgb(x, y, r, g, b);
        }
      }
    }

    // 2. Morphological stroke reinforcement (3x3 local min-filter on ink edges)
    // Ensures delicate Talekattu, Kombu, and Ottakshara subscripts stay intact when resized to 32/48px
    final reinforced = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = enhanced.getPixel(x, y);
        final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

        // If pixel is near ink stroke boundary (luma < 195)
        if (luma < 195.0) {
          int minR = p.r.toInt();
          int minG = p.g.toInt();
          int minB = p.b.toInt();

          for (int dy = -1; dy <= 1; dy++) {
            final ny = y + dy;
            if (ny < 0 || ny >= h) continue;
            for (int dx = -1; dx <= 1; dx++) {
              final nx = x + dx;
              if (nx < 0 || nx >= w) continue;
              final np = enhanced.getPixel(nx, ny);
              final nLuma = 0.299 * np.r + 0.587 * np.g + 0.114 * np.b;
              if (nLuma < luma) {
                if (np.r < minR) minR = np.r.toInt();
                if (np.g < minG) minG = np.g.toInt();
                if (np.b < minB) minB = np.b.toInt();
              }
            }
          }
          reinforced.setPixelRgb(x, y, minR, minG, minB);
        } else {
          reinforced.setPixelRgb(x, y, p.r.round(), p.g.round(), p.b.round());
        }
      }
    }

    return reinforced;
  }

  /// De-slants cursive / italic handwriting by estimating stroke inclination
  /// and applying horizontal shear compensation.
  static img.Image deSlantCrop(img.Image crop, {double maxSlantDegrees = 20.0}) {
    if (crop.width < 12 || crop.height < 12) return crop;
    final w = crop.width;
    final h = crop.height;

    double bestAlpha = 0.0;
    double maxVar = -1.0;

    for (double deg = -maxSlantDegrees; deg <= maxSlantDegrees; deg += 5.0) {
      final rad = deg * math.pi / 180.0;
      final tanA = math.tan(rad);
      final profile = List<double>.filled(w, 0.0);

      for (int y = 0; y < h; y++) {
        final shift = ((y - h / 2.0) * tanA).round();
        for (int x = 0; x < w; x++) {
          final srcX = x + shift;
          if (srcX >= 0 && srcX < w) {
            final p = crop.getPixel(srcX, y);
            final luma = 255.0 - (0.299 * p.r + 0.587 * p.g + 0.114 * p.b);
            if (luma > 35) profile[x] += luma;
          }
        }
      }

      final mean = profile.reduce((a, b) => a + b) / w;
      double variance = 0.0;
      for (final val in profile) {
        variance += (val - mean) * (val - mean);
      }
      if (variance > maxVar) {
        maxVar = variance;
        bestAlpha = rad;
      }
    }

    if (bestAlpha.abs() < 0.07) return crop;

    final tanA = math.tan(bestAlpha);
    final sheared = img.Image(width: w, height: h, numChannels: 3);
    img.fill(sheared, color: img.ColorRgb8(255, 255, 255));

    for (int y = 0; y < h; y++) {
      final shift = ((y - h / 2.0) * tanA);
      for (int x = 0; x < w; x++) {
        final srcX = x + shift;
        final x0 = srcX.floor();
        final x1 = x0 + 1;
        if (x0 >= 0 && x1 < w) {
          final fx = srcX - x0;
          final p0 = crop.getPixel(x0, y);
          final p1 = crop.getPixel(x1, y);
          final r = ((1.0 - fx) * p0.r + fx * p1.r).round().clamp(0, 255);
          final g = ((1.0 - fx) * p0.g + fx * p1.g).round().clamp(0, 255);
          final b = ((1.0 - fx) * p0.b + fx * p1.b).round().clamp(0, 255);
          sheared.setPixelRgb(x, y, r, g, b);
        } else if (x0 >= 0 && x0 < w) {
          final p0 = crop.getPixel(x0, y);
          sheared.setPixelRgb(x, y, p0.r.round(), p0.g.round(), p0.b.round());
        }
      }
    }
    return sheared;
  }
}

