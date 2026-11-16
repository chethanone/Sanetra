import 'dart:math' as math;
import 'currency_model_service.dart';

enum AnnouncementSafetyStatus {
  empty,
  confirmedSingle,
  confirmedMultiple,
  tentativeSingle,
  conflictingOrUncertain,
}

class CurrencySafetyAssessment {
  final AnnouncementSafetyStatus status;
  final List<CurrencyDetection> screenedDetections;
  final bool isTotalConfirmed;
  final int? confirmedTotalRupees;
  final int visibleDetectedSumRupees;
  final int confirmedCount;
  final int tentativeCount;
  final int conflictingCount;
  final bool hasUncertainCount;
  final Set<String> reasons;
  final String spokenMessage;
  final String bannerHeadline;
  final String bannerSubtitle;

  const CurrencySafetyAssessment({
    required this.status,
    required this.screenedDetections,
    required this.isTotalConfirmed,
    required this.confirmedTotalRupees,
    required this.visibleDetectedSumRupees,
    required this.confirmedCount,
    required this.tentativeCount,
    required this.conflictingCount,
    required this.hasUncertainCount,
    required this.reasons,
    required this.spokenMessage,
    required this.bannerHeadline,
    required this.bannerSubtitle,
  });
}

class CurrencySafetyEvaluator {
  const CurrencySafetyEvaluator._();

  static double computeIoU(CurrencyDetection a, CurrencyDetection b) {
    final xA = math.max(a.x1, b.x1);
    final yA = math.max(a.y1, b.y1);
    final xB = math.min(a.x2, b.x2);
    final yB = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xB - xA) * math.max(0.0, yB - yA);
    final union = a.area + b.area - inter;
    return union > 0.0 ? inter / union : 0.0;
  }

  static double computeIoMin(CurrencyDetection a, CurrencyDetection b) {
    final xA = math.max(a.x1, b.x1);
    final yA = math.max(a.y1, b.y1);
    final xB = math.min(a.x2, b.x2);
    final yB = math.min(a.y2, b.y2);
    final inter = math.max(0.0, xB - xA) * math.max(0.0, yB - yA);
    final minArea = math.min(a.area, b.area);
    return minArea > 0.0 ? inter / minArea : 0.0;
  }

  /// Screens every visible currency detection independently for confidence, class margin,
  /// suppressed alternate-class conflict, pairwise spatial overlap, cross-model banknote-coin
  /// containment conflicts, coin geometry sanity, and tracker stability.
  static CurrencySafetyAssessment evaluate(
    List<CurrencyDetection> detections, {
    bool candidateMode = true,
    bool hasUncertainObjectCount = false,
    Set<String> extraReasons = const {},
    int imageWidth = 0,
    int imageHeight = 0,
  }) {
    if (detections.isEmpty) {
      if (extraReasons.contains('FOREIGN_CURRENCY_DETECTED')) {
        return CurrencySafetyAssessment(
          status: AnnouncementSafetyStatus.conflictingOrUncertain,
          screenedDetections: const [],
          isTotalConfirmed: false,
          confirmedTotalRupees: null,
          visibleDetectedSumRupees: 0,
          confirmedCount: 0,
          tentativeCount: 0,
          conflictingCount: 1,
          hasUncertainCount: true,
          reasons: extraReasons,
          spokenMessage: 'Foreign currency detected, not counted.',
          bannerHeadline: 'Foreign currency',
          bannerSubtitle: 'Not Indian Rupees — not counted',
        );
      }
      if (extraReasons.contains('IDENTITY_UNKNOWN')) {
        return CurrencySafetyAssessment(
          status: AnnouncementSafetyStatus.conflictingOrUncertain,
          screenedDetections: const [],
          isTotalConfirmed: false,
          confirmedTotalRupees: null,
          visibleDetectedSumRupees: 0,
          confirmedCount: 0,
          tentativeCount: 1,
          conflictingCount: 0,
          hasUncertainCount: true,
          reasons: extraReasons,
          spokenMessage: 'Currency uncertain, hold steady and try again.',
          bannerHeadline: 'Currency uncertain',
          bannerSubtitle: 'Hold steady — cannot verify Indian currency',
        );
      }
      return const CurrencySafetyAssessment(
        status: AnnouncementSafetyStatus.empty,
        screenedDetections: [],
        isTotalConfirmed: false,
        confirmedTotalRupees: null,
        visibleDetectedSumRupees: 0,
        confirmedCount: 0,
        tentativeCount: 0,
        conflictingCount: 0,
        hasUncertainCount: false,
        reasons: {},
        spokenMessage: '',
        bannerHeadline: '',
        bannerSubtitle: '',
      );
    }

    if (!candidateMode) {
      final total = detections.fold<int>(0, (s, d) => s + d.value);
      return CurrencySafetyAssessment(
        status: detections.length == 1
            ? AnnouncementSafetyStatus.confirmedSingle
            : AnnouncementSafetyStatus.confirmedMultiple,
        screenedDetections: detections,
        isTotalConfirmed: true,
        confirmedTotalRupees: total,
        visibleDetectedSumRupees: total,
        confirmedCount: detections.length,
        tentativeCount: 0,
        conflictingCount: 0,
        hasUncertainCount: false,
        reasons: const {},
        spokenMessage: _buildConfirmedSpeech(detections, total, includeConfirmedPrefix: false),
        bannerHeadline: _buildBreakdownHeadline(detections),
        bannerSubtitle: '${detections.length} item${detections.length == 1 ? '' : 's'} in view',
      );
    }

    final screened = <CurrencyDetection>[];
    final allReasons = <String>{...extraReasons};
    int confirmedCount = 0;
    int tentativeCount = 0;
    int conflictingCount = 0;
    bool overlapHazard = false;
    bool classConflictHazard = false;

    final double frameArea = (imageWidth > 0 && imageHeight > 0)
        ? (imageWidth.toDouble() * imageHeight.toDouble())
        : 0.0;

    for (int i = 0; i < detections.length; i++) {
      final d = detections[i];
      double maxIoU = d.interBoxMaxIoU;
      double maxIoMin = d.interBoxMaxIoMin;
      double maxCrossModelBanknoteIoMin = 0.0;
      double maxEnclosingNoteAreaFrac = 0.0;

      // Pairwise inter-box overlap among same-type items (note vs note, coin vs coin)
      // plus cross-model banknote containment checks for coins.
      for (int j = 0; j < detections.length; j++) {
        if (i == j) continue;
        final other = detections[j];
        if (other.isCoin == d.isCoin) {
          final iou = computeIoU(d, other);
          final iomin = computeIoMin(d, other);
          if (iou > maxIoU) maxIoU = iou;
          if (iomin > maxIoMin) maxIoMin = iomin;
        } else if (d.isCoin &&
            !other.isCoin &&
            other.confidence >= CurrencyModelService.candidateConfirmConfThreshold &&
            !other.isConflicting) {
          final crossIoMin = computeIoMin(d, other);
          if (crossIoMin > maxCrossModelBanknoteIoMin) {
            maxCrossModelBanknoteIoMin = crossIoMin;
          }
          if (crossIoMin >= CurrencyModelService.candidateCoinCrossModelIoMin &&
              frameArea > 0.0) {
            final noteAreaFrac = other.area / frameArea;
            if (noteAreaFrac > maxEnclosingNoteAreaFrac) {
              maxEnclosingNoteAreaFrac = noteAreaFrac;
            }
          }
        }
      }

      final reasons = <String>{...d.uncertaintyReasons};

      final bool hasMissingStale = d.framesMissing > 0;
      final bool hasOverlap =
          maxIoU > CurrencyModelService.candidateMaxInterBoxIoU ||
              maxIoMin > CurrencyModelService.candidateMaxInterBoxIoMin;
      final bool hasSuppressedConflict =
          d.suppressedConflictConfidence >= CurrencyModelService.candidateMaxSuppressedConflict;

      final double areaFrac = frameArea > 0.0 ? d.area / frameArea : 1.0;
      final double coinAspect = (d.isCoin && d.width > 0.0 && d.height > 0.0)
          ? d.width / d.height
          : 1.0;
      final bool enclosedByOversizedNote = frameArea > 0.0 &&
          maxEnclosingNoteAreaFrac >=
              CurrencyModelService.candidateSpuriousWrapperNoteMinAreaFrac;
      final bool qualifiesAsGenuineCoinOnNote = d.isCoin &&
          !enclosedByOversizedNote &&
          !hasSuppressedConflict &&
          d.confidence >= CurrencyModelService.candidateCoinConfirmConfThreshold &&
          d.classMargin >= CurrencyModelService.candidateCoinOnNoteMinMargin &&
          (frameArea <= 0.0 ||
              areaFrac >= CurrencyModelService.candidateCoinOnNoteMinAreaFrac) &&
          coinAspect >= CurrencyModelService.candidateCoinOnNoteMinAspect &&
          coinAspect <= CurrencyModelService.candidateCoinOnNoteMaxAspect;
      final bool hasCrossModelConflict = d.isCoin &&
          maxCrossModelBanknoteIoMin >= CurrencyModelService.candidateCoinCrossModelIoMin &&
          (enclosedByOversizedNote || !qualifiesAsGenuineCoinOnNote);

      final double minConf = d.isCoin
          ? CurrencyModelService.candidateCoinConfirmConfThreshold
          : CurrencyModelService.candidateConfirmConfThreshold;
      final double minMargin = d.isCoin
          ? CurrencyModelService.candidateCoinMinClassMargin
          : CurrencyModelService.candidateMinClassMargin;

      final bool isLowConf = d.confidence < minConf;
      final bool isNarrowMargin = d.classMargin < minMargin;

      final bool hasCoinExtremeAspect = d.isCoin &&
          d.width > 0.0 &&
          d.height > 0.0 &&
          (coinAspect < CurrencyModelService.candidateCoinMinAspectRatio ||
              coinAspect > CurrencyModelService.candidateCoinMaxAspectRatio);
      final bool hasSmallCoinArea = d.isCoin &&
          frameArea > 0.0 &&
          areaFrac < CurrencyModelService.candidateCoinMinAreaFrac;

      if (hasMissingStale) reasons.add('STALE_TRACK');
      if (hasOverlap) {
        reasons.add('OVERLAP_CONFLICT');
        overlapHazard = true;
      }
      if (hasSuppressedConflict) {
        reasons.add('CROSS_CLASS_CONFLICT');
        classConflictHazard = true;
      }
      if (hasCrossModelConflict) {
        reasons.add('CROSS_MODEL_BANKNOTE_CONFLICT');
        classConflictHazard = true;
      }
      if (isLowConf) reasons.add('LOW_CONFIDENCE');
      if (isNarrowMargin) reasons.add('NARROW_CLASS_MARGIN');
      if (hasCoinExtremeAspect) reasons.add('COIN_EXTREME_ASPECT_RATIO');
      if (hasSmallCoinArea) reasons.add('SMALL_COIN_AREA');

      final DetectionConfirmationState state;
      if (hasOverlap ||
          hasSuppressedConflict ||
          hasCrossModelConflict ||
          reasons.contains('CLASS_OSCILLATION')) {
        state = DetectionConfirmationState.conflicting;
        conflictingCount++;
        if (reasons.contains('CLASS_OSCILLATION')) {
          classConflictHazard = true;
        }
      } else if (isLowConf ||
          isNarrowMargin ||
          hasMissingStale ||
          hasCoinExtremeAspect ||
          hasSmallCoinArea ||
          d.isTentative) {
        state = DetectionConfirmationState.tentative;
        tentativeCount++;
      } else {
        state = DetectionConfirmationState.confirmed;
        confirmedCount++;
      }

      allReasons.addAll(reasons);
      screened.add(
        d.copyWith(
          interBoxMaxIoU: maxIoU,
          interBoxMaxIoMin: maxIoMin,
          confirmationState: state,
          uncertaintyReasons: reasons.toList(),
        ),
      );
    }

    final bool hasIdentityBlock = allReasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        allReasons.contains('IDENTITY_UNKNOWN');
    final bool uncertainCount = hasUncertainObjectCount ||
        overlapHazard ||
        hasIdentityBlock ||
        allReasons.contains('AMBIGUOUS_COUNT') ||
        allReasons.contains('MERGED_BOX_SUSPECTED');

    if (uncertainCount) {
      allReasons.add('UNCERTAIN_COUNT');
    }

    final int visibleSum = screened.fold<int>(0, (s, d) => s + d.value);
    final bool allConfirmed =
        conflictingCount == 0 && tentativeCount == 0 && !uncertainCount;

    if (allConfirmed) {
      final status = screened.length == 1
          ? AnnouncementSafetyStatus.confirmedSingle
          : AnnouncementSafetyStatus.confirmedMultiple;
      return CurrencySafetyAssessment(
        status: status,
        screenedDetections: screened,
        isTotalConfirmed: true,
        confirmedTotalRupees: visibleSum,
        visibleDetectedSumRupees: visibleSum,
        confirmedCount: confirmedCount,
        tentativeCount: 0,
        conflictingCount: 0,
        hasUncertainCount: false,
        reasons: allReasons,
        spokenMessage: _buildConfirmedSpeech(screened, visibleSum, includeConfirmedPrefix: true),
        bannerHeadline: _buildBreakdownHeadline(screened),
        bannerSubtitle: 'CONFIRMED · ${screened.length} item${screened.length == 1 ? '' : 's'}',
      );
    }

    // Tentative single note without conflict or ambiguous count -> recognize tentatively without confirming total
    if (screened.length == 1 && conflictingCount == 0 && !uncertainCount) {
      final d = screened.first;
      final spokenUnit = CurrencyModelService.formatItemSpokenName(d.denomination, d.value);
      final displayUnit = CurrencyModelService.formatItemDisplayName(d.denomination, d.value);
      return CurrencySafetyAssessment(
        status: AnnouncementSafetyStatus.tentativeSingle,
        screenedDetections: screened,
        isTotalConfirmed: false,
        confirmedTotalRupees: null,
        visibleDetectedSumRupees: visibleSum,
        confirmedCount: confirmedCount,
        tentativeCount: tentativeCount,
        conflictingCount: 0,
        hasUncertainCount: false,
        reasons: allReasons,
        spokenMessage:
            'Possible $spokenUnit, not confirmed. Hold steady in better light and try again.',
        bannerHeadline: 'Possible $displayUnit',
        bannerSubtitle: 'TENTATIVE · Low certainty — total not confirmed',
      );
    }

    // Multiple / Conflicting / Uncertain count -> DO NOT announce sum as confirmed total
    final String spokenGuidance;
    final String subtitle;
    if (allReasons.contains('INCOMPLETE_SCENE')) {
      spokenGuidance =
          'Some currency items are temporarily unclear. Please hold steady in better light and try again.';
      subtitle = 'INCOMPLETE SCENE · Waiting for steady view';
    } else if (overlapHazard || uncertainCount) {
      spokenGuidance =
          'Some notes are unclear or overlapping. Please spread them apart and try again.';
      subtitle = 'UNCERTAIN COUNT · Spread stacked or overlapping notes';
    } else if (classConflictHazard) {
      spokenGuidance =
          'Denomination conflict detected. Please adjust lighting or angle and try again.';
      subtitle = 'CONFLICT DETECTED · Total withheld';
    } else {
      spokenGuidance =
          'Some notes are unclear. Please spread them apart in better light and try again.';
      subtitle = 'PARTIAL / UNCONFIRMED · Hold steady';
    }

    return CurrencySafetyAssessment(
      status: AnnouncementSafetyStatus.conflictingOrUncertain,
      screenedDetections: screened,
      isTotalConfirmed: false,
      confirmedTotalRupees: null,
      visibleDetectedSumRupees: visibleSum,
      confirmedCount: confirmedCount,
      tentativeCount: tentativeCount,
      conflictingCount: conflictingCount,
      hasUncertainCount: uncertainCount,
      reasons: allReasons,
      spokenMessage: spokenGuidance,
      bannerHeadline: 'Unclear / Unconfirmed (${screened.length})',
      bannerSubtitle: subtitle,
    );
  }

  static String _buildBreakdownHeadline(List<CurrencyDetection> detections) {
    final countMap = <String, int>{};
    for (final d in detections) {
      final name = CurrencyModelService.formatItemDisplayName(d.denomination, d.value);
      countMap[name] = (countMap[name] ?? 0) + 1;
    }
    return countMap.entries.map((e) => '${e.value}× ${e.key}').join(' · ');
  }

  static String _buildConfirmedSpeech(
    List<CurrencyDetection> detections,
    int total, {
    required bool includeConfirmedPrefix,
  }) {
    if (detections.length == 1) {
      final d = detections.first;
      return CurrencyModelService.formatItemSpokenName(d.denomination, d.value);
    }

    final countMap = <String, int>{};
    final valueMap = <String, int>{};
    for (final d in detections) {
      countMap[d.denomination] = (countMap[d.denomination] ?? 0) + 1;
      valueMap[d.denomination] = d.value;
    }

    final parts = <String>[];
    countMap.forEach((denom, count) {
      final val = valueMap[denom] ?? 0;
      final spokenUnit = CurrencyModelService.formatItemSpokenName(denom, val);
      parts.add(count == 1 ? spokenUnit : '$count $spokenUnit' 's');
    });

    final prefix = includeConfirmedPrefix ? 'Confirmed total' : 'Total';
    return '${parts.join(', ')}. $prefix, $total Rupees';
  }
}

