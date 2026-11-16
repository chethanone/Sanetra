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
}

