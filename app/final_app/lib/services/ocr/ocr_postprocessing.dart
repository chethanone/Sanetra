import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'ocr_result.dart';

class OcrPostprocessing {
  static const double defaultThreshold = 0.30;
  static const double defaultBoxThreshold = 0.60;
  static const double defaultUnclipRatio = 1.50;
  static const int minComponentArea = 25;

  /// Extract text region polygons from detector probability map.
  ///
  /// [predMap]: Flattened probability map of shape `[targetHeight, targetWidth]`.
  static List<OcrPolygon> extractTextPolygons({
    required Float32List predMap,
    required int targetWidth,
    required int targetHeight,
    required double scaleX,
    required double scaleY,
    required int origWidth,
    required int origHeight,
    double threshold = defaultThreshold,
    double boxThreshold = defaultBoxThreshold,
    double unclipRatio = defaultUnclipRatio,
  }) {
    final int totalPixels = targetWidth * targetHeight;
    final visited = Uint8List(totalPixels);

    final polygons = <OcrPolygon>[];

    // Queue for BFS connected component analysis
    final queueX = Int32List(totalPixels);
    final queueY = Int32List(totalPixels);

    // Component coordinates buffers
    final compX = Int32List(totalPixels);
    final compY = Int32List(totalPixels);

    for (int y = 0; y < targetHeight; y++) {
      for (int x = 0; x < targetWidth; x++) {
        final int startIdx = y * targetWidth + x;
        if (visited[startIdx] == 1 || predMap[startIdx] < threshold) {
          continue;
        }

        // Start BFS to collect all connected pixels in this component
        int head = 0;
        int tail = 0;
        queueX[tail] = x;
        queueY[tail] = y;
        tail++;
        visited[startIdx] = 1;

        int compCount = 0;
        double sumScore = 0.0;

        while (head < tail) {
          final curX = queueX[head];
          final curY = queueY[head];
          head++;

          final curIdx = curY * targetWidth + curX;
          compX[compCount] = curX;
          compY[compCount] = curY;
          compCount++;
          sumScore += predMap[curIdx];

          // Check 4-connected neighbors
          final neighborsX = [curX + 1, curX - 1, curX, curX];
          final neighborsY = [curY, curY, curY + 1, curY - 1];

          for (int i = 0; i < 4; i++) {
            final nx = neighborsX[i];
            final ny = neighborsY[i];

            if (nx >= 0 && nx < targetWidth && ny >= 0 && ny < targetHeight) {
              final nIdx = ny * targetWidth + nx;
              if (visited[nIdx] == 0 && predMap[nIdx] >= threshold) {
                visited[nIdx] = 1;
                queueX[tail] = nx;
                queueY[tail] = ny;
                tail++;
              }
            }
          }
        }

        // Filter out components that are too small
        if (compCount < minComponentArea) continue;

        // Filter out components with average score below boxThreshold
        final double avgScore = sumScore / compCount;
        if (avgScore < boxThreshold) continue;

        // Compute oriented bounding box using 2D moments (PCA)
        double meanX = 0.0;
        double meanY = 0.0;
        for (int i = 0; i < compCount; i++) {
          meanX += compX[i];
          meanY += compY[i];
        }
        meanX /= compCount;
        meanY /= compCount;

        double u20 = 0.0;
        double u02 = 0.0;
        double u11 = 0.0;
        for (int i = 0; i < compCount; i++) {
          final dx = compX[i] - meanX;
          final dy = compY[i] - meanY;
          u20 += dx * dx;
          u02 += dy * dy;
          u11 += dx * dy;
        }
        u20 /= compCount;
        u02 /= compCount;
        u11 /= compCount;

        // Orientation angle theta
        final double theta = 0.5 * math.atan2(2 * u11, u20 - u02);
        final double cosT = math.cos(theta);
        final double sinT = math.sin(theta);

        // Project all component points onto principal axes
        double minP1 = double.infinity;
        double maxP1 = -double.infinity;
        double minP2 = double.infinity;
        double maxP2 = -double.infinity;

        for (int i = 0; i < compCount; i++) {
          final dx = compX[i] - meanX;
          final dy = compY[i] - meanY;
          final p1 = dx * cosT + dy * sinT;
          final p2 = -dx * sinT + dy * cosT;

          if (p1 < minP1) minP1 = p1;
          if (p1 > maxP1) maxP1 = p1;
          if (p2 < minP2) minP2 = p2;
          if (p2 > maxP2) maxP2 = p2;
        }

        double boxW = maxP1 - minP1;
        double boxH = maxP2 - minP2;

        if (boxW < 4 || boxH < 4) continue;

        // Box center in target coordinates
        final c1 = (minP1 + maxP1) / 2.0;
        final c2 = (minP2 + maxP2) / 2.0;
        final boxCenterX = meanX + c1 * cosT - c2 * sinT;
        final boxCenterY = meanY + c1 * sinT + c2 * cosT;

        // Ensure boxW is the long side along text direction
        double unclipW = boxW;
        double unclipH = boxH;

        // DB unclip expansion
        final double perimeter = 2.0 * (unclipW + unclipH);
        final double area = unclipW * unclipH;
        final double dist = (area * unclipRatio) / perimeter;

        unclipW += 2.0 * dist;
        unclipH += 2.0 * dist;

        final hw = unclipW / 2.0;
        final hh = unclipH / 2.0;

        // 4 corners relative to center
        final localCorners = [
          [-hw, -hh],
          [hw, -hh],
          [hw, hh],
          [-hw, hh],
        ];

        final worldPts = <OcrPoint>[];
        for (final corner in localCorners) {
          final rx = corner[0] * cosT - corner[1] * sinT + boxCenterX;
          final ry = corner[0] * sinT + corner[1] * cosT + boxCenterY;

          // Scale back to original image
          final origX = (rx * scaleX).clamp(0.0, origWidth.toDouble() - 1.0);
          final origY = (ry * scaleY).clamp(0.0, origHeight.toDouble() - 1.0);
          worldPts.add(OcrPoint(origX, origY));
        }

        final double angleDegrees = theta * 180.0 / math.pi;

        // Order corners: Top-Left, Top-Right, Bottom-Right, Bottom-Left
        final ordered = _orderPoints(worldPts, angleDegrees);

        // Phase 5.11: Curved-text centerline & curvature analysis along PCA major axis
        List<OcrPoint> centerline = const [];
        double curveHalfHeight = 0.0;
        String geometryType = 'straight';

        if (boxW >= boxH * 2.2 && compCount >= 24) {
          const int numSlices = 8;
          final sliceSumP2 = List<double>.filled(numSlices, 0.0);
          final sliceCount = List<int>.filled(numSlices, 0);
          final sliceMinP2 = List<double>.filled(numSlices, double.infinity);
          final sliceMaxP2 = List<double>.filled(numSlices, -double.infinity);
          final double spanP1 = math.max(1e-3, maxP1 - minP1);

          for (int i = 0; i < compCount; i++) {
            final dx = compX[i] - meanX;
            final dy = compY[i] - meanY;
            final p1 = dx * cosT + dy * sinT;
            final p2 = -dx * sinT + dy * cosT;
            final int b = (((p1 - minP1) / spanP1) * numSlices)
                .floor()
                .clamp(0, numSlices - 1);
            sliceSumP2[b] += p2;
            sliceCount[b]++;
            if (p2 < sliceMinP2[b]) sliceMinP2[b] = p2;
            if (p2 > sliceMaxP2[b]) sliceMaxP2[b] = p2;
          }

          final rawP1 = <double>[];
          final rawP2 = <double>[];
          double localHeightSum = 0.0;
          int validBins = 0;
          for (int b = 0; b < numSlices; b++) {
            if (sliceCount[b] > 0) {
              rawP1.add(minP1 + ((b + 0.5) / numSlices) * spanP1);
              rawP2.add(sliceSumP2[b] / sliceCount[b]);
              localHeightSum += (sliceMaxP2[b] - sliceMinP2[b]);
              validBins++;
            }
          }

          if (validBins >= 4) {
            final double avgLocalH = math.max(2.0, localHeightSum / validBins);
            final double firstP1 = rawP1.first;
            final double lastP1 = rawP1.last;
            final double firstP2 = rawP2.first;
            final double lastP2 = rawP2.last;
            final double p1Diff = math.max(1e-3, lastP1 - firstP1);
            double maxChordDev = 0.0;
            for (int k = 1; k < rawP1.length - 1; k++) {
              final t = (rawP1[k] - firstP1) / p1Diff;
              final lineP2 = firstP2 + t * (lastP2 - firstP2);
              final dev = (rawP2[k] - lineP2).abs();
              if (dev > maxChordDev) maxChordDev = dev;
            }

            if (maxChordDev / avgLocalH >= 0.22) {
              geometryType = 'curved';
              curveHalfHeight =
                  ((avgLocalH * 0.5) + dist) * ((scaleX + scaleY) * 0.5);
              final pts = <OcrPoint>[];
              for (int k = 0; k < rawP1.length; k++) {
                // Extend endpoints slightly by `dist` along tangent direction
                double p1Val = rawP1[k];
                if (k == 0) p1Val -= dist * 0.6;
                if (k == rawP1.length - 1) p1Val += dist * 0.6;
                final rx = p1Val * cosT - rawP2[k] * sinT + meanX;
                final ry = p1Val * sinT + rawP2[k] * cosT + meanY;
                pts.add(
                  OcrPoint(
                    (rx * scaleX).clamp(0.0, origWidth.toDouble() - 1.0),
                    (ry * scaleY).clamp(0.0, origHeight.toDouble() - 1.0),
                  ),
                );
              }
              // Ensure consistent forward text direction along PCA major axis (cosT, sinT)
              if (pts.length >= 2) {
                final uFirst = pts.first.x * cosT + pts.first.y * sinT;
                final uLast = pts.last.x * cosT + pts.last.y * sinT;
                if (uFirst > uLast) {
                  centerline = pts.reversed.toList();
                } else {
                  centerline = pts;
                }
              }
            }
          }
        }

        polygons.add(
          OcrPolygon(
            topLeft: ordered[0],
            topRight: ordered[1],
            bottomRight: ordered[2],
            bottomLeft: ordered[3],
            score: avgScore,
            centerline: centerline,
            curveHalfHeight: curveHalfHeight,
            geometryType: geometryType,
            angleDegrees: angleDegrees,
          ),
        );
      }
    }

    return polygons;
  }

  /// Order 4 polygon points into [topLeft, topRight, bottomRight, bottomLeft]
  /// oriented along the polygon's text angle.
  static List<OcrPoint> _orderPoints(List<OcrPoint> pts, [double angleDegrees = 0.0]) {
    if (pts.length != 4) return pts;

    final rad = angleDegrees * math.pi / 180.0;
    final cosT = math.cos(rad);
    final sinT = math.sin(rad);

    // Project points into oriented box coordinates (u along text, v down)
    final projected = <({OcrPoint pt, double u, double v})>[];
    for (final p in pts) {
      projected.add((
        pt: p,
        u: p.x * cosT + p.y * sinT,
        v: -p.x * sinT + p.y * cosT,
      ));
    }

    // Sort by v (top vs bottom)
    projected.sort((a, b) => a.v.compareTo(b.v));
    final topTwo = [projected[0], projected[1]]..sort((a, b) => a.u.compareTo(b.u));
    final bottomTwo = [projected[2], projected[3]]..sort((a, b) => a.u.compareTo(b.u));

    final tl = topTwo[0].pt;
    final tr = topTwo[1].pt;
    final bl = bottomTwo[0].pt;
    final br = bottomTwo[1].pt;

    return [tl, tr, br, bl];
  }

  /// Crop and rectify either a curved text region (along its centerline) or a
  /// planar polygon region (perspective homography).
  static img.Image? extractRegionCrop({
    required img.Image originalImage,
    required OcrPolygon polygon,
    bool allowAutoVerticalRotate = false,
  }) {
    if (polygon.isCurved) {
      final curved = extractCurvedCrop(
        originalImage: originalImage,
        polygon: polygon,
      );
      if (curved != null) return curved;
    }
    return extractPerspectiveCrop(
      originalImage: originalImage,
      polygon: polygon,
      allowAutoVerticalRotate: allowAutoVerticalRotate,
    );
  }

  /// Unwrap a curved text region along its centerline into a straight horizontal strip.
  static img.Image? extractCurvedCrop({
    required img.Image originalImage,
    required OcrPolygon polygon,
  }) {
    final pts = polygon.centerline;
    if (pts.length < 3) return null;

    final segLens = <double>[];
    final cumLens = <double>[0.0];
    double totalLen = 0.0;
    for (int i = 0; i < pts.length - 1; i++) {
      final len = pts[i].distanceTo(pts[i + 1]);
      segLens.add(len);
      totalLen += len;
      cumLens.add(totalLen);
    }

    final int cropW = totalLen.round();
    final double halfH = polygon.curveHalfHeight > 3.0
        ? polygon.curveHalfHeight
        : math.max(6.0, math.min(polygon.height, polygon.width) * 0.45);
    final int cropH = (halfH * 2.0).round();

    if (cropW < 8 || cropH < 6) return null;

    final cropped = img.Image(width: cropW, height: cropH, numChannels: 3);
    final origW = originalImage.width;
    final origH = originalImage.height;

    // Precompute smooth unit normals at each centerline vertex
    final normals = <OcrPoint>[];
    for (int i = 0; i < pts.length; i++) {
      final prev = pts[math.max(0, i - 1)];
      final next = pts[math.min(pts.length - 1, i + 1)];
      final tx = next.x - prev.x;
      final ty = next.y - prev.y;
      final mag = math.sqrt(tx * tx + ty * ty);
      if (mag < 1e-6) {
        normals.add(normals.isNotEmpty ? normals.last : const OcrPoint(0.0, 1.0));
      } else {
        // Unit normal perpendicular to tangent: (-ty/mag, tx/mag)
        double nx = -ty / mag;
        double ny = tx / mag;
        // Keep normal continuous across curve: ensure dot product with previous normal is positive
        if (normals.isNotEmpty) {
          final dot = nx * normals.last.x + ny * normals.last.y;
          if (dot < 0) {
            nx = -nx;
            ny = -ny;
          }
        }
        normals.add(OcrPoint(nx, ny));
      }
    }

    int segIdx = 0;
    for (int x = 0; x < cropW; x++) {
      final double u = cropW > 1 ? (x / (cropW - 1)) * totalLen : 0.0;
      while (segIdx < segLens.length - 1 && u > cumLens[segIdx + 1]) {
        segIdx++;
      }
      final double segLen = math.max(1e-6, segLens[segIdx]);
      final double localT = ((u - cumLens[segIdx]) / segLen).clamp(0.0, 1.0);
      final cx = pts[segIdx].x + (pts[segIdx + 1].x - pts[segIdx].x) * localT;
      final cy = pts[segIdx].y + (pts[segIdx + 1].y - pts[segIdx].y) * localT;
      double nx = normals[segIdx].x + (normals[segIdx + 1].x - normals[segIdx].x) * localT;
      double ny = normals[segIdx].y + (normals[segIdx + 1].y - normals[segIdx].y) * localT;
      final nMag = math.sqrt(nx * nx + ny * ny);
      if (nMag > 1e-6) {
        nx /= nMag;
        ny /= nMag;
      }

      for (int y = 0; y < cropH; y++) {
        final double v = cropH > 1 ? ((y / (cropH - 1)) * 2.0 - 1.0) * halfH : 0.0;
        final double srcX = cx + nx * v;
        final double srcY = cy + ny * v;

        final int x0 = srcX.floor().clamp(0, origW - 1);
        final int y0 = srcY.floor().clamp(0, origH - 1);
        final int x1 = math.min(x0 + 1, origW - 1);
        final int y1 = math.min(y0 + 1, origH - 1);

        final double fx = (srcX - x0).clamp(0.0, 1.0);
        final double fy = (srcY - y0).clamp(0.0, 1.0);

        final p00 = originalImage.getPixel(x0, y0);
        final p10 = originalImage.getPixel(x1, y0);
        final p01 = originalImage.getPixel(x0, y1);
        final p11 = originalImage.getPixel(x1, y1);

        final r = _bilerp(p00.r, p10.r, p01.r, p11.r, fx, fy).round().clamp(0, 255);
        final g = _bilerp(p00.g, p10.g, p01.g, p11.g, fx, fy).round().clamp(0, 255);
        final b = _bilerp(p00.b, p10.b, p01.b, p11.b, fx, fy).round().clamp(0, 255);
        cropped.setPixelRgb(x, y, r, g, b);
      }
    }

    return cropped;
  }

  static double _bilerp(
    num c00,
    num c10,
    num c01,
    num c11,
    double fx,
    double fy,
  ) {
    return (1 - fx) * (1 - fy) * c00 +
        fx * (1 - fy) * c10 +
        (1 - fx) * fy * c01 +
        fx * fy * c11;
  }

  /// Crop and perspective-correct a text region polygon from the original image.
  static img.Image? extractPerspectiveCrop({
    required img.Image originalImage,
    required OcrPolygon polygon,
    bool allowAutoVerticalRotate = true,
  }) {
    final p0 = polygon.topLeft;
    final p1 = polygon.topRight;
    final p2 = polygon.bottomRight;
    final p3 = polygon.bottomLeft;

    final double widthTop = p0.distanceTo(p1);
    final double widthBottom = p3.distanceTo(p2);
    final int cropW = math.max(widthTop, widthBottom).round();

    final double heightLeft = p0.distanceTo(p3);
    final double heightRight = p1.distanceTo(p2);
    final int cropH = math.max(heightLeft, heightRight).round();

    if (cropW < 6 || cropH < 6) return null;

    final cropped = img.Image(width: cropW, height: cropH, numChannels: 3);

    // Solve perspective transformation matrix from destination (0..cropW-1, 0..cropH-1)
    // to source image coordinates (p0, p1, p2, p3)
    final dx1 = p1.x - p2.x;
    final dx2 = p3.x - p2.x;
    final dx3 = p0.x - p1.x + p2.x - p3.x;

    final dy1 = p1.y - p2.y;
    final dy2 = p3.y - p2.y;
    final dy3 = p0.y - p1.y + p2.y - p3.y;

    final det = dx1 * dy2 - dx2 * dy1;

    double a11, a12, a13, a21, a22, a23, a31, a32;

    if (det.abs() < 1e-7) {
      // Affine fallback
      a11 = p1.x - p0.x;
      a12 = p1.y - p0.y;
      a13 = 0.0;
      a21 = p3.x - p0.x;
      a22 = p3.y - p0.y;
      a23 = 0.0;
      a31 = p0.x;
      a32 = p0.y;
    } else {
      a13 = (dx3 * dy2 - dx2 * dy3) / det;
      a23 = (dx1 * dy3 - dx3 * dy1) / det;
      a11 = p1.x - p0.x + a13 * p1.x;
      a12 = p1.y - p0.y + a13 * p1.y;
      a21 = p3.x - p0.x + a23 * p3.x;
      a22 = p3.y - p0.y + a23 * p3.y;
      a31 = p0.x;
      a32 = p0.y;
    }

    final double invW = cropW > 1 ? 1.0 / (cropW - 1) : 1.0;
    final double invH = cropH > 1 ? 1.0 / (cropH - 1) : 1.0;

    final origW = originalImage.width;
    final origH = originalImage.height;

    for (int yd = 0; yd < cropH; yd++) {
      final v = yd * invH;
      for (int xd = 0; xd < cropW; xd++) {
        final u = xd * invW;

        final wp = a13 * u + a23 * v + 1.0;
        final xs = (a11 * u + a21 * v + a31) / wp;
        final ys = (a12 * u + a22 * v + a32) / wp;

        // Bilinear interpolation
        final int x0 = xs.floor().clamp(0, origW - 1);
        final int y0 = ys.floor().clamp(0, origH - 1);
        final int x1 = (x0 + 1).clamp(0, origW - 1);
        final int y1 = (y0 + 1).clamp(0, origH - 1);

        final double wx = (xs - x0).clamp(0.0, 1.0);
        final double wy = (ys - y0).clamp(0.0, 1.0);

        final p00 = originalImage.getPixel(x0, y0);
        final p10 = originalImage.getPixel(x1, y0);
        final p01 = originalImage.getPixel(x0, y1);
        final p11 = originalImage.getPixel(x1, y1);

        final r = ((1 - wx) * (1 - wy) * p00.r +
                wx * (1 - wy) * p10.r +
                (1 - wx) * wy * p01.r +
                wx * wy * p11.r)
            .round()
            .clamp(0, 255);

        final g = ((1 - wx) * (1 - wy) * p00.g +
                wx * (1 - wy) * p10.g +
                (1 - wx) * wy * p01.g +
                wx * wy * p11.g)
            .round()
            .clamp(0, 255);

        final b = ((1 - wx) * (1 - wy) * p00.b +
                wx * (1 - wy) * p10.b +
                (1 - wx) * wy * p01.b +
                wx * wy * p11.b)
            .round()
            .clamp(0, 255);

        cropped.setPixelRgb(xd, yd, r, g, b);
      }
    }

    // PP-OCRv5 requires horizontal text input (W >= H).
    // If text was detected oriented vertically (e.g. medicine bottles held upright),
    // rotate 90 degrees clockwise so characters align with the recognizer.
    // Phase 5.11 recognition passes allowAutoVerticalRotate=false and evaluates 90 vs 270 deg.
    if (allowAutoVerticalRotate && cropH > cropW * 1.15) {
      return img.copyRotate(cropped, angle: 90);
    }

    return cropped;
  }

  /// Sort recognized lines into natural reading order while preserving detected
  /// per-line language and uncertainty metadata.
  static List<OcrLineResult> sortReadingOrder(List<OcrLineResult> items) {
    return analyzeSceneAndOrder(items).lines;
  }

  /// Analyze spatial layout (sections, boxes, columns, headings, curved/vertical regions),
  /// suppress duplicate overlapping regions, order lines intelligently according to the
  /// section-first line-by-line reading rule, and produce a concise blind-friendly scene summary.
  static ({List<OcrLineResult> lines, String sceneSummary}) analyzeSceneAndOrder(
    List<OcrLineResult> items, {
    int imageWidth = 0,
    int imageHeight = 0,
  }) {
    if (items.isEmpty) {
      return (lines: const [], sceneSummary: '');
    }

    final deduped = _suppressOverlappingLines(items);
    if (deduped.isEmpty) {
      return (lines: const [], sceneSummary: '');
    }

    final int effW = imageWidth > 0
        ? imageWidth
        : deduped.map((e) => e.polygon.maxX).reduce(math.max).ceil().clamp(1, 10000);
    final int effH = imageHeight > 0
        ? imageHeight
        : deduped.map((e) => e.polygon.maxY).reduce(math.max).ceil().clamp(1, 10000);

    // 1. Detect dominant rotation angle from lines (full 360-degree rotation invariance)
    final double domAngleDeg = _detectDominantAngle(deduped);
    final double rad = domAngleDeg * math.pi / 180.0;
    final double cosP = math.cos(rad);
    final double sinP = math.sin(rad);

    // Project lines into canonical document coordinate frame:
    // u along the document reading direction (start to end of lines)
    // v along the document line progression (top to bottom of page)
    final orientedLines = deduped.map((line) {
      return _toOrientedLine(line, cosP, sinP);
    }).toList();

    // 2. Check for prominent signboard heading first (large font, prominent position)
    bool hasProminentHeading = false;
    _OrientedLine? prominentHeading;
    final otherLines = <_OrientedLine>[];

    if (orientedLines.length >= 2 && orientedLines.length <= 6) {
      final heights = orientedLines.map((e) => e.height).toList()..sort();
      final medianH = heights[heights.length ~/ 2];
      for (final line in orientedLines) {
        final isBig = medianH > 0 &&
            line.height >= medianH * 1.55 &&
            line.width >= effW * 0.18;
        if (isBig && prominentHeading == null) {
          prominentHeading = line;
          hasProminentHeading = true;
        } else {
          otherLines.add(line);
        }
      }
    } else {
      otherLines.addAll(orientedLines);
    }

    // 3. Partition content into cohesive Sections / Boxes / Columns
    final sections = _clusterIntoSections(otherLines, effW);

    // 4. Group sections sharing the same vertical space into Section Rows (left-to-right tiers)
    // Rule: "first read one complete section, look for immediate next section in the same space,
    // if not go down and follow the rule till the end"
    final sectionRows = _groupSectionsIntoRows(sections);

    // 5. Order lines within each section strictly line-by-line, and traverse sections row-by-row
    final ordered = <OcrLineResult>[];
    int sectionCounter = 0;

    if (prominentHeading != null) {
      ordered.add(prominentHeading.raw.copyWith(isHeading: true, columnIndex: 0));
      sectionCounter++;
    }

    for (final row in sectionRows) {
      for (final sec in row) {
        final secLines = _sortSingleSectionLines(sec.lines);
        for (final line in secLines) {
          ordered.add(line.copyWith(columnIndex: sectionCounter));
        }
        sectionCounter++;
      }
    }

    // 6. Assign final line indices and spatial position descriptions
    final finalLines = <OcrLineResult>[];
    for (int i = 0; i < ordered.length; i++) {
      final l = ordered[i];
      final pos = _describePointPosition(
        l.polygon.centerX,
        l.polygon.centerY,
        effW,
        effH,
      );
      finalLines.add(
        l.copyWith(
          lineIndex: i + 1,
          spatialPosition: pos,
        ),
      );
    }

    final maxSecInRow = sectionRows.fold<int>(0, (m, r) => math.max(m, r.length));
    final summary = _buildSceneSummary(
      finalLines,
      effW,
      effH,
      columnCount: maxSecInRow,
      hasProminentHeading: hasProminentHeading,
    );

    return (lines: finalLines, sceneSummary: summary);
  }

  static double _detectDominantAngle(List<OcrLineResult> items) {
    if (items.isEmpty) return 0.0;
    double sumSin = 0.0;
    double sumCos = 0.0;
    int count = 0;

    for (final item in items) {
      if (item.confidence >= 0.50 && item.text.trim().isNotEmpty) {
        // True 360-degree orientation combining polygon baseline tilt and recognition rotation.
        // If polygon.angleDegrees already reflects the dominant tilt (|angle| > 45), don't
        // double-add 90/270 degree rotation.
        double lineAngle = item.polygon.angleDegrees;
        if (item.orientationDegrees == 180) {
          if (lineAngle.abs() <= 90.0) {
            lineAngle += 180.0;
          }
        } else if (item.orientationDegrees != 0) {
          if (lineAngle.abs() <= 45.0) {
            lineAngle += item.orientationDegrees;
          }
        }

        final rad = lineAngle * math.pi / 180.0;
        final weight = item.confidence * math.max(1.0, math.min(10.0, item.text.trim().length.toDouble()));
        sumSin += weight * math.sin(rad);
        sumCos += weight * math.cos(rad);
        count++;
      }
    }

    if (count == 0) return 0.0;
    final r = math.sqrt(sumSin * sumSin + sumCos * sumCos);
    if (r < 1e-4) return 0.0;

    double domRad = math.atan2(sumSin, sumCos);
    double domDeg = domRad * 180.0 / math.pi;
    if (domDeg < 0) domDeg += 360.0;

    // Snap within 3.0 degrees of principal axes (0, 90, 180, 270)
    if (domDeg < 3.0 || domDeg > 357.0) return 0.0;
    if ((domDeg - 180.0).abs() <= 3.0) return 180.0;
    if ((domDeg - 90.0).abs() <= 3.0) return 90.0;
    if ((domDeg - 270.0).abs() <= 3.0) return 270.0;

    return domDeg;
  }

  static _OrientedLine _toOrientedLine(
    OcrLineResult line,
    double cosP,
    double sinP,
  ) {
    final pts = line.polygon.points;
    double minU = double.infinity;
    double maxU = -double.infinity;
    double minV = double.infinity;
    double maxV = -double.infinity;

    for (final p in pts) {
      final u = p.x * cosP + p.y * sinP;
      final v = -p.x * sinP + p.y * cosP;
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    return _OrientedLine(
      raw: line,
      uMin: minU,
      uMax: maxU,
      vMin: minV,
      vMax: maxV,
    );
  }

  /// Clusters lines into cohesive Sections / Boxes using spatial proximity and gutter analysis.
  static List<_LayoutSection> _clusterIntoSections(
    List<_OrientedLine> items,
    int effW,
  ) {
    if (items.isEmpty) return const [];
    if (items.length == 1) return [_LayoutSection(items)];

    final heights = items.map((e) => e.height).toList()..sort();
    final medianH = heights[heights.length ~/ 2];
    final vProxThresh = math.max(16.0, medianH * 1.85);

    // Build adjacency list for connected-component clustering
    final n = items.length;
    final adj = List<List<int>>.generate(n, (_) => []);

    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        final a = items[i];
        final b = items[j];

        // Vertical distance between lines
        final double vGap = a.vMin > b.vMax
            ? a.vMin - b.vMax
            : (b.vMin > a.vMax ? b.vMin - a.vMax : 0.0);

        if (vGap > vProxThresh) continue;

        // Check horizontal overlap and margin alignment
        final hOverlap = math.max(0.0, math.min(a.uMax, b.uMax) - math.max(a.uMin, b.uMin));
        final minW = math.min(a.width, b.width);
        final overlapRatio = minW > 0 ? hOverlap / minW : 0.0;
        final leftAligned = (a.uMin - b.uMin).abs() <= math.max(14.0, medianH * 1.35);
        final centerAligned = (a.uCenter - b.uCenter).abs() <= math.max(18.0, medianH * 1.55);

        // Disjoint gutter check: If separated horizontally by clear empty space, do NOT connect
        final double hGap = a.uMin > b.uMax
            ? a.uMin - b.uMax
            : (b.uMin > a.uMax ? b.uMin - a.uMax : 0.0);
        final bool hasHorizontalGutter = hGap > math.max(16.0, medianH * 0.75);

        if (!hasHorizontalGutter && (overlapRatio >= 0.20 || leftAligned || centerAligned)) {
          adj[i].add(j);
          adj[j].add(i);
        }
      }
    }

    // Traverse connected components
    final visited = List<bool>.filled(n, false);
    final sections = <_LayoutSection>[];

    for (int i = 0; i < n; i++) {
      if (visited[i]) continue;
      final compLines = <_OrientedLine>[];
      final queue = <int>[i];
      visited[i] = true;

      while (queue.isNotEmpty) {
        final cur = queue.removeLast();
        compLines.add(items[cur]);
        for (final neighbor in adj[cur]) {
          if (!visited[neighbor]) {
            visited[neighbor] = true;
            queue.add(neighbor);
          }
        }
      }
      sections.add(_LayoutSection(compLines));
    }

    return sections;
  }

  /// Groups sections into horizontal rows / tiers of sections sharing the same vertical space.
  /// Sections within each row are sorted left-to-right (increasing uMin).
  /// Rows are sorted from top to bottom (increasing vMin).
  static List<List<_LayoutSection>> _groupSectionsIntoRows(
    List<_LayoutSection> sections,
  ) {
    if (sections.isEmpty) return const [];
    if (sections.length == 1) return [sections];

    // Sort sections primarily by vertical start
    final sorted = List<_LayoutSection>.from(sections)
      ..sort((a, b) => a.vMin.compareTo(b.vMin));

    final rows = <List<_LayoutSection>>[];

    for (final sec in sorted) {
      bool placed = false;
      for (final row in rows) {
        final rowVMin = row.map((s) => s.vMin).reduce(math.min);
        final rowVMax = row.map((s) => s.vMax).reduce(math.max);
        final rowH = math.max(1.0, rowVMax - rowVMin);
        final minH = math.min(sec.height, rowH);

        final overlap = math.max(0.0, math.min(sec.vMax, rowVMax) - math.max(sec.vMin, rowVMin));
        if (overlap >= minH * 0.35) {
          row.add(sec);
          placed = true;
          break;
        }
      }
      if (!placed) {
        rows.add([sec]);
      }
    }

    // Sort rows top-to-bottom
    rows.sort((a, b) {
      final aMin = a.map((s) => s.vMin).reduce(math.min);
      final bMin = b.map((s) => s.vMin).reduce(math.min);
      return aMin.compareTo(bMin);
    });

    // Within each row, sort sections left-to-right (increasing uMin)
    for (final row in rows) {
      row.sort((a, b) => a.uMin.compareTo(b.uMin));
    }

    return rows;
  }

  /// Sorts lines within a single section strictly line-by-line from top to bottom,
  /// sorting multiple words/fragments on the same line left-to-right.
  static List<OcrLineResult> _sortSingleSectionLines(List<_OrientedLine> items) {
    if (items.isEmpty) return const [];
    if (items.length == 1) return [items.first.raw];

    final sorted = List<_OrientedLine>.from(items)
      ..sort((a, b) => a.vCenter.compareTo(b.vCenter));

    final List<List<_OrientedLine>> visualLines = [];
    List<_OrientedLine> currentLine = [];
    double currentCenterV = sorted.first.vCenter;
    double currentHeight = sorted.first.height;

    for (final item in sorted) {
      if (currentLine.isEmpty) {
        currentLine.add(item);
        currentCenterV = item.vCenter;
        currentHeight = item.height;
      } else {
        final bandThreshold = math.max(8.0, math.min(currentHeight, item.height) * 0.55);
        if ((item.vCenter - currentCenterV).abs() < bandThreshold) {
          currentLine.add(item);
          currentCenterV = currentLine.fold<double>(0.0, (s, e) => s + e.vCenter) / currentLine.length;
          currentHeight = currentLine.fold<double>(0.0, (s, e) => s + e.height) / currentLine.length;
        } else {
          visualLines.add(currentLine);
          currentLine = [item];
          currentCenterV = item.vCenter;
          currentHeight = item.height;
        }
      }
    }
    if (currentLine.isNotEmpty) {
      visualLines.add(currentLine);
    }

    final result = <OcrLineResult>[];
    for (final vLine in visualLines) {
      vLine.sort((a, b) => a.uMin.compareTo(b.uMin));
      result.addAll(vLine.map((e) => e.raw));
    }
    return result;
  }

  static List<OcrLineResult> _suppressOverlappingLines(List<OcrLineResult> items) {
    final sorted = List<OcrLineResult>.from(items)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <OcrLineResult>[];
    for (final cand in sorted) {
      bool duplicate = false;
      for (final existing in kept) {
        if (_bboxIoU(cand.polygon, existing.polygon) > 0.65) {
          duplicate = true;
          break;
        }
      }
      if (!duplicate) {
        kept.add(cand);
      }
    }
    return kept;
  }

  static double _bboxIoU(OcrPolygon a, OcrPolygon b) {
    final ix1 = math.max(a.minX, b.minX);
    final iy1 = math.max(a.minY, b.minY);
    final ix2 = math.min(a.maxX, b.maxX);
    final iy2 = math.min(a.maxY, b.maxY);
    final iw = math.max(0.0, ix2 - ix1);
    final ih = math.max(0.0, iy2 - iy1);
    final inter = iw * ih;
    if (inter <= 0.0) return 0.0;
    final union = a.width * a.height + b.width * b.height - inter;
    return union > 0.0 ? inter / union : 0.0;
  }

  static List<OcrLineResult> _sortSingleColumnLines(List<OcrLineResult> items) {
    if (items.length <= 1) return List<OcrLineResult>.from(items);

    final sorted = List<OcrLineResult>.from(items)
      ..sort((a, b) => a.polygon.centerY.compareTo(b.polygon.centerY));

    final List<List<OcrLineResult>> lines = [];
    List<OcrLineResult> currentLine = [];
    double currentCenterY = sorted.first.polygon.centerY;
    double currentLineHeight = math.max(12.0, sorted.first.polygon.height);

    for (final item in sorted) {
      if (currentLine.isEmpty) {
        currentLine.add(item);
        currentCenterY = item.polygon.centerY;
        currentLineHeight = math.max(12.0, item.polygon.height);
      } else {
        final double itemH = math.max(12.0, item.polygon.height);
        final double bandThreshold = math.max(8.0, math.min(currentLineHeight, itemH) * 0.60);
        if ((item.polygon.centerY - currentCenterY).abs() < bandThreshold) {
          currentLine.add(item);
          currentCenterY = currentLine.fold<double>(0.0, (s, e) => s + e.polygon.centerY) / currentLine.length;
          currentLineHeight = currentLine.fold<double>(0.0, (s, e) => s + math.max(12.0, e.polygon.height)) / currentLine.length;
        } else {
          lines.add(currentLine);
          currentLine = [item];
          currentCenterY = item.polygon.centerY;
          currentLineHeight = itemH;
        }
      }
    }
    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    final result = <OcrLineResult>[];
    for (final line in lines) {
      line.sort((a, b) => a.polygon.centerX.compareTo(b.polygon.centerX));
      result.addAll(line);
    }
    return result;
  }

  static String _describePointPosition(
    double cx,
    double cy,
    int imgW,
    int imgH,
  ) {
    final nx = imgW > 0 ? cx / imgW : 0.5;
    final ny = imgH > 0 ? cy / imgH : 0.5;
    final vPos = ny < 0.35 ? 'top' : (ny > 0.65 ? 'bottom' : 'middle');
    final hPos = nx < 0.35 ? 'left' : (nx > 0.65 ? 'right' : 'center');
    if (vPos == 'middle' && hPos == 'center') return 'center';
    if (vPos == 'middle') return hPos;
    if (hPos == 'center') return vPos;
    return '$vPos-$hPos';
  }

  static String _buildSceneSummary(
    List<OcrLineResult> lines,
    int imgW,
    int imgH, {
    required int columnCount,
    required bool hasProminentHeading,
  }) {
    if (lines.isEmpty) return '';
    double sumX = 0.0;
    double sumY = 0.0;
    double minX = double.infinity;
    double maxX = 0.0;
    bool hasCurved = false;
    for (final l in lines) {
      sumX += l.polygon.centerX;
      sumY += l.polygon.centerY;
      if (l.polygon.minX < minX) minX = l.polygon.minX;
      if (l.polygon.maxX > maxX) maxX = l.polygon.maxX;
      if (l.geometryType == 'curved') hasCurved = true;
    }
    final cx = (sumX / lines.length) / math.max(1, imgW);
    final cy = (sumY / lines.length) / math.max(1, imgH);

    final parts = <String>[];
    if (columnCount >= 2) {
      parts.add('$columnCount-column layout detected.');
    } else if (hasProminentHeading) {
      parts.add('Signboard heading first.');
    } else if (hasCurved) {
      parts.add('Curved label text.');
    }

    if (cx < 0.30) {
      parts.add('Text is on the left.');
    } else if (cx > 0.70) {
      parts.add('Text is on the right.');
    } else if (cy < 0.28) {
      parts.add('Text is near the top.');
    } else if (cy > 0.72) {
      parts.add('Text is near the bottom.');
    } else {
      parts.add('Text centered.');
    }

    if (minX <= imgW * 0.02 || maxX >= imgW * 0.98) {
      parts.add('Move back slightly if edges are cut off.');
    }
    return parts.join(' ');
  }
}

class _OrientedLine {
  final OcrLineResult raw;
  final double uMin;
  final double uMax;
  final double vMin;
  final double vMax;
  final double uCenter;
  final double vCenter;
  final double width;
  final double height;

  _OrientedLine({
    required this.raw,
    required this.uMin,
    required this.uMax,
    required this.vMin,
    required this.vMax,
  })  : uCenter = (uMin + uMax) / 2.0,
        vCenter = (vMin + vMax) / 2.0,
        width = math.max(1.0, uMax - uMin),
        height = math.max(1.0, vMax - vMin);
}

class _LayoutSection {
  final List<_OrientedLine> lines;
  double uMin;
  double uMax;
  double vMin;
  double vMax;

  _LayoutSection(this.lines)
      : uMin = lines.isEmpty ? 0.0 : lines.map((l) => l.uMin).reduce(math.min),
        uMax = lines.isEmpty ? 0.0 : lines.map((l) => l.uMax).reduce(math.max),
        vMin = lines.isEmpty ? 0.0 : lines.map((l) => l.vMin).reduce(math.min),
        vMax = lines.isEmpty ? 0.0 : lines.map((l) => l.vMax).reduce(math.max);

  double get width => math.max(1.0, uMax - uMin);
  double get height => math.max(1.0, vMax - vMin);
  double get uCenter => (uMin + uMax) / 2.0;
  double get vCenter => (vMin + vMax) / 2.0;
}

