import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:vision_assistant/services/currency_model_service.dart';

class BanknoteOverlayPainter extends CustomPainter {
  final List<CurrencyDetection> detections;
  final int imageWidth;
  final int imageHeight;

  const BanknoteOverlayPainter({
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
  });

  static Color getColorForValue(int value, {String denomination = ''}) {
    if (denomination.contains('COIN') || value < 10) {
      switch (value) {
        case 1:
          return const Color(0xFFD7CCC8); // Copper / bronze
        case 2:
          return const Color(0xFFE0E0E0); // Bright silver
        case 5:
          return const Color(0xFFFFD54F); // Golden brass
        case 10:
          return const Color(0xFFFFCA28); // Bimetallic gold
        default:
          return const Color(0xFFFFE082);
      }
    }

    switch (value) {
      case 10:
        return const Color(0xFFFFB300); // Amber / Chocolate
      case 20:
        return const Color(0xFF7CB342); // Lime green
      case 50:
        return const Color(0xFF00E5FF); // Fluorescent cyan
      case 100:
        return const Color(0xFFBA68C8); // Lavender
      case 200:
        return const Color(0xFFFF9100); // Bright orange
      case 500:
        return const Color(0xFF00BFA5); // Stone mint
      default:
        return const Color(0xFF00E5FF);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty || imageWidth <= 0 || imageHeight <= 0) {
      return;
    }

    // BoxFit.cover geometry calculation
    final double scaleX = size.width / imageWidth.toDouble();
    final double scaleY = size.height / imageHeight.toDouble();
    final double renderScale = math.max(scaleX, scaleY);

    final double offsetX = (size.width - imageWidth * renderScale) / 2.0;
    final double offsetY = (size.height - imageHeight * renderScale) / 2.0;

    for (final detection in detections) {
      final left = (detection.x1 * renderScale + offsetX).clamp(0.0, size.width);
      final top = (detection.y1 * renderScale + offsetY).clamp(0.0, size.height);
      final right = (detection.x2 * renderScale + offsetX).clamp(0.0, size.width);
      final bottom = (detection.y2 * renderScale + offsetY).clamp(0.0, size.height);

      if (right <= left || bottom <= top) continue;

      final rect = Rect.fromLTRB(left, top, right, bottom);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
      final Color color;
      if (detection.isConflicting) {
        color = const Color(0xFFFF5252);
      } else if (detection.isTentative) {
        color = const Color(0xFFFFD54F);
      } else {
        color = getColorForValue(detection.value, denomination: detection.denomination);
      }

      // 1. Soft Outer Glow
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
      canvas.drawRRect(rrect, glowPaint);

      // 2. Main Box Stroke
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawRRect(rrect, boxPaint);

      // 3. Subtle semi-transparent inner tint
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rrect, fillPaint);

      // 4. Camera Focus Brackets (Corner Reticles)
      final bracketPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      const double bracketLen = 16.0;

      // Top-Left
      canvas.drawLine(Offset(rect.left, rect.top + bracketLen), Offset(rect.left, rect.top), bracketPaint);
      canvas.drawLine(Offset(rect.left, rect.top), Offset(rect.left + bracketLen, rect.top), bracketPaint);

      // Top-Right
      canvas.drawLine(Offset(rect.right - bracketLen, rect.top), Offset(rect.right, rect.top), bracketPaint);
      canvas.drawLine(Offset(rect.right, rect.top), Offset(rect.right, rect.top + bracketLen), bracketPaint);

      // Bottom-Left
      canvas.drawLine(Offset(rect.left, rect.bottom - bracketLen), Offset(rect.left, rect.bottom), bracketPaint);
      canvas.drawLine(Offset(rect.left, rect.bottom), Offset(rect.left + bracketLen, rect.bottom), bracketPaint);

      // Bottom-Right
      canvas.drawLine(Offset(rect.right - bracketLen, rect.bottom), Offset(rect.right, rect.bottom), bracketPaint);
      canvas.drawLine(Offset(rect.right, rect.bottom), Offset(rect.right, rect.bottom - bracketLen), bracketPaint);

      // 5. Floating Denomination Badge
      final isCoin = detection.denomination.contains('COIN') || detection.value < 10;
      final baseLabel = isCoin ? '₹${detection.value} Coin' : '₹${detection.value}';
      final labelText = detection.isConflicting
          ? '$baseLabel ?'
          : (detection.isTentative ? '~$baseLabel' : baseLabel);
      final textSpan = TextSpan(
        children: [
          TextSpan(
            text: '$labelText  ',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          TextSpan(
            text: '${(detection.confidence * 100).toInt()}%',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final badgeW = textPainter.width + 16.0;
      const double badgeH = 26.0;
      final badgeX = rect.left + 4.0;
      final badgeY = math.max(0.0, rect.top - badgeH - 4.0);

      final badgeRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(badgeX, badgeY, badgeW, badgeH),
        const Radius.circular(6),
      );

      // Badge background
      final badgeBgPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(badgeRRect, badgeBgPaint);

      // Badge border accent
      final badgeBorderPaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRRect(badgeRRect, badgeBorderPaint);

      // Paint text inside badge
      textPainter.paint(
        canvas,
        Offset(badgeX + 8.0, badgeY + (badgeH - textPainter.height) / 2.0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BanknoteOverlayPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight;
  }
}

