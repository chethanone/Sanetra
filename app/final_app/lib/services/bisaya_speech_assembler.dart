import 'currency_safety_evaluator.dart';

/// Assembles ordered offline Bisaya (`ceb-PH`) `.wav` clip IDs for instant,
/// zero-synthesis-latency currency & selector announcements.
class BisayaSpeechAssembler {
  const BisayaSpeechAssembler._();

  static const Map<int, String> _tensClips = {
    20: 'tens_20',
    30: 'tens_30',
    40: 'tens_40',
    50: 'tens_50',
    60: 'tens_60',
    70: 'tens_70',
    80: 'tens_80',
    90: 'tens_90',
  };

  /// Assemble clip IDs for any non-negative integer [n] (`0..999,999`).
  static List<String> clipsForNumber(int n) {
    if (n <= 19) {
      return ['num_${n < 0 ? 0 : n}'];
    }
    if (n < 100) {
      final t = (n ~/ 10) * 10;
      final u = n % 10;
      final tClip = _tensClips[t]!;
      return u == 0 ? [tClip] : [tClip, 'conj_ug', 'num_$u'];
    }
    if (n < 1000) {
      final h = n ~/ 100;
      final rem = n % 100;
      final out = <String>['num_$h', 'part_ka', 'unit_gatos'];
      if (rem > 0) {
        out.add('conj_ug');
        out.addAll(clipsForNumber(rem));
      }
      return out;
    }
    if (n < 1000000) {
      final k = n ~/ 1000;
      final rem = n % 1000;
      final out = <String>[...clipsForNumber(k), 'part_ka', 'unit_libo'];
      if (rem > 0) {
        out.add('conj_ug');
        out.addAll(clipsForNumber(rem));
      }
      return out;
    }
    return ['num_0'];
  }

  /// Assemble clip IDs for a grouped denomination, e.g. `(INR_200, 200, 2)`.
  static List<String> clipsForGroup(String denomination, int value, int count) {
    final bool isCoin = denomination.toUpperCase().contains('COIN');
    return <String>[
      ...clipsForNumber(count),
      'part_ka',
      ...clipsForNumber(value),
      'part_ka',
      'unit_rupee',
      'part_nga',
      isCoin ? 'unit_sensilyo' : 'unit_papel',
    ];
  }

  /// Assemble clip IDs for a [CurrencySafetyAssessment].
  static List<String> clipsForAssessment(CurrencySafetyAssessment assessment) {
    switch (assessment.status) {
      case AnnouncementSafetyStatus.empty:
        return const ['prompt_empty'];
      case AnnouncementSafetyStatus.conflictingOrUncertain:
        if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
            assessment.reasons.contains('UNCERTAIN_COUNT')) {
          return const ['warn_overlap'];
        }
        return const ['warn_conflict'];
      case AnnouncementSafetyStatus.tentativeSingle:
        final d = assessment.screenedDetections.first;
        return <String>[
          'prefix_possible',
          ...clipsForGroup(d.denomination, d.value, 1),
          'suffix_not_confirmed',
        ];
      case AnnouncementSafetyStatus.confirmedSingle:
        final d = assessment.screenedDetections.first;
        return clipsForGroup(d.denomination, d.value, 1);
      case AnnouncementSafetyStatus.confirmedMultiple:
        final counts = <String, int>{};
        final values = <String, int>{};
        for (final d in assessment.screenedDetections) {
          counts[d.denomination] = (counts[d.denomination] ?? 0) + 1;
          values[d.denomination] = d.value;
        }
        final groups = <List<String>>[];
        counts.forEach((denom, count) {
          groups.add(clipsForGroup(denom, values[denom] ?? 0, count));
        });
        final out = <String>[];
        for (int i = 0; i < groups.length; i++) {
          if (i > 0) out.add('conj_ug');
          out.addAll(groups[i]);
        }
        final total =
            assessment.confirmedTotalRupees ?? assessment.visibleDetectedSumRupees;
        out.add('prefix_total');
        out.addAll(clipsForNumber(total));
        out.add('unit_rupee');
        return out;
    }
  }
}
