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
      if (extraReasons.contains('INVALID_CURRENCY_DETECTED') ||
          extraReasons.contains('FOREIGN_CURRENCY_DETECTED')) {
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
          spokenMessage: 'Invalid',
          bannerHeadline: 'Invalid',
          bannerSubtitle: 'Invalid currency',
        );
      }
      if (extraReasons.contains('UNRECOGNISED_CURRENCY') ||
          extraReasons.contains('IDENTITY_UNKNOWN')) {
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
          spokenMessage: 'Unrecognised currency. Hold steady and try again.',
          bannerHeadline: 'Unrecognised',
          bannerSubtitle: 'Unrecognised · Hold steady',
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
      double maxCrossClassIoU = d.interBoxMaxIoU;
      double maxCrossClassIoMin = d.interBoxMaxIoMin;
      double maxCrossModelBanknoteIoMin = 0.0;
      double maxEnclosingNoteAreaFrac = 0.0;
      bool hasTrueOverlapConflict = false;

      // Pairwise inter-box overlap among same-type items (note vs note, coin vs coin)
      // plus cross-model banknote containment checks for coins.
      for (int j = 0; j < detections.length; j++) {
        if (i == j) continue;
        final other = detections[j];
        if (other.isCoin == d.isCoin) {
          final iou = computeIoU(d, other);
          final iomin = computeIoMin(d, other);

          final dDiag = math.sqrt(d.width * d.width + d.height * d.height);
          final oDiag = math.sqrt(other.width * other.width + other.height * other.height);
          final minDiag = math.min(dDiag, oDiag);
          final dx = d.centerX - other.centerX;
          final dy = d.centerY - other.centerY;
          final normCenterDist = minDiag > 0.0 ? math.sqrt(dx * dx + dy * dy) / minDiag : 1.0;
          final isCoLocated = normCenterDist < 0.20 && (iou >= 0.60 || iomin >= 0.80);

          // Only cross-class pairs can trigger overlap conflict; same denomination held together is valid
          if (d.classId != other.classId) {
            if (iou > maxCrossClassIoU) maxCrossClassIoU = iou;
            if (iomin > maxCrossClassIoMin) maxCrossClassIoMin = iomin;
            if (isCoLocated) {
              hasTrueOverlapConflict = true;
            }
          }
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
      final bool hasOverlap = hasTrueOverlapConflict ||
          maxCrossClassIoU > CurrencyModelService.candidateMaxInterBoxIoU ||
          maxCrossClassIoMin > CurrencyModelService.candidateMaxInterBoxIoMin;
      final bool isSuppressed25Conflict = ((d.denomination == 'INR_2_COIN' && d.suppressedConflictClassName == 'INR_5_COIN') ||
          (d.denomination == 'INR_5_COIN' && d.suppressedConflictClassName == 'INR_2_COIN')) &&
          (d.confidence >= 0.88 && d.classMargin >= 0.50);
      final bool isSuppressed12Conflict = ((d.denomination == 'INR_1_COIN' && d.suppressedConflictClassName == 'INR_2_COIN') ||
          (d.denomination == 'INR_2_COIN' && d.suppressedConflictClassName == 'INR_1_COIN')) &&
          (d.confidence >= 0.45 && d.classMargin >= 0.12);
      final bool hasSuppressedConflict =
          d.suppressedConflictConfidence >= CurrencyModelService.candidateMaxSuppressedConflict &&
          !isSuppressed25Conflict &&
          !isSuppressed12Conflict;

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
          interBoxMaxIoU: maxCrossClassIoU,
          interBoxMaxIoMin: maxCrossClassIoMin,
          confirmationState: state,
          uncertaintyReasons: reasons.toList(),
        ),
      );
    }

    final bool hasInvalidCurrency = allReasons.contains('INVALID_CURRENCY_DETECTED') ||
        allReasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        screened.any((d) => d.denomination == 'INVALID' || d.uncertaintyReasons.contains('INVALID_CURRENCY_DETECTED'));
    final bool hasUnrecognisedCurrency = allReasons.contains('UNRECOGNISED_CURRENCY') ||
        allReasons.contains('IDENTITY_UNKNOWN') ||
        screened.any((d) => d.denomination == 'UNRECOGNISED' || d.uncertaintyReasons.contains('UNRECOGNISED_CURRENCY'));

    final bool hasIdentityBlock = hasInvalidCurrency || hasUnrecognisedCurrency;
    final bool uncertainCount = hasUncertainObjectCount ||
        overlapHazard ||
        hasIdentityBlock ||
        allReasons.contains('AMBIGUOUS_COUNT') ||
        allReasons.contains('MERGED_BOX_SUSPECTED');

    if (uncertainCount) {
      allReasons.add('UNCERTAIN_COUNT');
    }

    final int visibleSum = screened.fold<int>(0, (s, d) => s + d.value);

    final confirmed = screened.where((d) => d.confirmationState == DetectionConfirmationState.confirmed).toList();
    final tentative = screened.where((d) => d.confirmationState == DetectionConfirmationState.tentative).toList();
    final conflicting = screened.where((d) => d.confirmationState == DetectionConfirmationState.conflicting).toList();

    // 1. SAFETY GATE: Active conflict, oscillation, or hand-occluded disagreement MUST trigger assistive guidance!
    final bool hasConflict = conflicting.isNotEmpty ||
        conflictingCount > 0 ||
        hasInvalidCurrency ||
        allReasons.contains('INCOMPLETE_SCENE') ||
        allReasons.contains('OVERLAP_CONFLICT') ||
        allReasons.contains('CROSS_CLASS_CONFLICT') ||
        allReasons.contains('CLASS_OSCILLATION') ||
        allReasons.contains('HAND_OCCLUDED_SPLIT_DISAGREEMENT');

    final String conflictGuidance;
    final String conflictSubtitle;
    final String conflictHeadline;
    if (hasInvalidCurrency) {
      conflictGuidance = 'Invalid';
      conflictHeadline = 'Invalid';
      conflictSubtitle = 'INVALID · Not valid currency';
    } else if (hasUnrecognisedCurrency && confirmed.isEmpty) {
      conflictGuidance = 'Unrecognised currency. Hold steady and try again.';
      conflictHeadline = 'Unrecognised';
      conflictSubtitle = 'UNRECOGNISED · Hold steady';
    } else if (allReasons.contains('INCOMPLETE_SCENE')) {
      conflictGuidance =
          'Some currency items are temporarily unclear. Please hold steady in better light and try again.';
      conflictHeadline = 'Incomplete scene';
      conflictSubtitle = 'INCOMPLETE SCENE · Waiting for steady view';
    } else if (allReasons.contains('TRUNCATED_OR_OCCLUDED_NOTE') ||
        allReasons.contains('HAND_OCCLUDED_SPLIT_DISAGREEMENT')) {
      conflictGuidance =
          'Difficult to denominate. Currency is partially covered, please uncover the note.';
      conflictHeadline = 'Difficult to denominate';
      conflictSubtitle = 'NOTE COVERED · Uncover to verify';
    } else if (allReasons.contains('MERGED_BOX_SUSPECTED') ||
        allReasons.contains('UNCERTAIN_COUNT') ||
        overlapHazard) {
      conflictGuidance =
          'Difficult to denominate. Multiple currencies may be overlapping, please spread them apart to verify count.';
      conflictHeadline = 'Difficult to denominate';
      conflictSubtitle = 'UNCERTAIN COUNT · Spread stacked notes';
    } else {
      conflictGuidance =
          'Difficult to denominate. Please adjust lighting or angle and try again.';
      conflictHeadline = 'Difficult to denominate';
      conflictSubtitle = 'CONFLICT DETECTED · Hold steady';
    }

    if (hasConflict) {
      return CurrencySafetyAssessment(
        status: AnnouncementSafetyStatus.conflictingOrUncertain,
        screenedDetections: screened,
        isTotalConfirmed: false,
        confirmedTotalRupees: null,
        visibleDetectedSumRupees: visibleSum,
        confirmedCount: 0,
        tentativeCount: tentative.length,
        conflictingCount: conflicting.isNotEmpty ? conflicting.length : (conflictingCount > 0 ? conflictingCount : 1),
        hasUncertainCount: true,
        reasons: allReasons,
        spokenMessage: conflictGuidance,
        bannerHeadline: conflictHeadline,
        bannerSubtitle: conflictSubtitle,
      );
    }

    // 2. SAFETY GATE: Confirmed items announce their denomination immediately!
    if (confirmed.isNotEmpty) {
      final int confirmedSum = confirmed.fold<int>(0, (s, d) => s + d.value);
      final status = confirmed.length == 1
          ? AnnouncementSafetyStatus.confirmedSingle
          : AnnouncementSafetyStatus.confirmedMultiple;
      final bool totalConfirmed = tentative.isEmpty && conflicting.isEmpty;
      return CurrencySafetyAssessment(
        status: status,
        screenedDetections: screened,
        isTotalConfirmed: totalConfirmed,
        confirmedTotalRupees: totalConfirmed ? confirmedSum : null,
        visibleDetectedSumRupees: visibleSum,
        confirmedCount: confirmed.length,
        tentativeCount: tentative.length,
        conflictingCount: 0,
        hasUncertainCount: !totalConfirmed,
        reasons: allReasons,
        spokenMessage: _buildConfirmedSpeech(confirmed, confirmedSum, includeConfirmedPrefix: candidateMode),
        bannerHeadline: _buildBreakdownHeadline(confirmed),
        bannerSubtitle: 'RECOGNIZED · ${confirmed.length} item${confirmed.length == 1 ? '' : 's'}',
      );
    }

    if (tentative.isNotEmpty) {
      final String tentativeSpeech;
      final bool isCovered = allReasons.contains('TRUNCATED_OR_OCCLUDED_NOTE') ||
          allReasons.contains('HAND_OCCLUDED_SPLIT_DISAGREEMENT');
      if (isCovered) {
        tentativeSpeech =
            'Difficult to denominate. Currency is partially covered, please uncover the note.';
      } else if (allReasons.contains('MERGED_BOX_SUSPECTED')) {
        tentativeSpeech =
            'Difficult to denominate. Multiple currencies may be overlapping, please spread them apart to verify count.';
      } else if (hasUnrecognisedCurrency ||
          allReasons.contains('IDENTITY_UNKNOWN') ||
          allReasons.contains('UNRECOGNISED_CURRENCY')) {
        tentativeSpeech =
            'Unrecognised currency. Hold steady and try again.';
      } else if (tentative.length == 1) {
        final d = tentative.first;
        final spokenUnit =
            CurrencyModelService.formatItemSpokenName(d.denomination, d.value);
        tentativeSpeech =
            'Difficult to denominate. Possible $spokenUnit, not confirmed. Hold steady in better light and try again.';
      } else {
        tentativeSpeech =
            'Difficult to denominate. Hold steady in better light and try again.';
      }

      return CurrencySafetyAssessment(
        status: AnnouncementSafetyStatus.tentativeSingle,
        screenedDetections: tentative,
        isTotalConfirmed: false,
        confirmedTotalRupees: null,
        visibleDetectedSumRupees: visibleSum,
        confirmedCount: 0,
        tentativeCount: tentative.length,
        conflictingCount: 0,
        hasUncertainCount: false,
        reasons: allReasons,
        spokenMessage: tentativeSpeech,
        bannerHeadline: isCovered
            ? 'Note partially covered'
            : 'Difficult to denominate',
        bannerSubtitle: isCovered
            ? 'Uncover note to verify denomination'
            : 'Hold still for confirmation',
      );
    }

    return CurrencySafetyAssessment(
      status: AnnouncementSafetyStatus.empty,
      screenedDetections: const [],
      isTotalConfirmed: false,
      confirmedTotalRupees: null,
      visibleDetectedSumRupees: 0,
      confirmedCount: 0,
      tentativeCount: 0,
      conflictingCount: 0,
      hasUncertainCount: false,
      reasons: allReasons,
      spokenMessage: '',
      bannerHeadline: 'No Currency Visible',
      bannerSubtitle: 'Align banknote or coin within frame',
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

