import 'bisaya_number_normalizer.dart';
import 'currency_model_service.dart';
import 'currency_safety_evaluator.dart';
import 'kannada_number_normalizer.dart';

/// Formats [CurrencySafetyAssessment] objects into natural, unambiguous speech
/// in English (`en-IN`), Kannada (`kn-IN`), and Hindi (`hi-IN`).
///
/// Keeps denomination, item count, and total as separate typed values so TTS
/// engines never concatenate count + denomination (e.g. `2` + `200` -> `2200`).
class CurrencySpeechFormatter {
  const CurrencySpeechFormatter._();

  static const List<String> _enUnits = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];

  static const List<String> _enTens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];

  /// Convert a non-negative integer [n] (0..999,999) into English words.
  static String numberToEnglishWords(int n) {
    if (n < 0) return 'minus ${numberToEnglishWords(-n)}';
    if (n < 20) return _enUnits[n];
    if (n < 100) {
      final t = n ~/ 10;
      final u = n % 10;
      return u == 0 ? _enTens[t] : '${_enTens[t]}-${_enUnits[u]}';
    }
    if (n < 1000) {
      final h = n ~/ 100;
      final rem = n % 100;
      if (rem == 0) return '${_enUnits[h]} hundred';
      return '${_enUnits[h]} hundred and ${numberToEnglishWords(rem)}';
    }
    if (n < 1000000) {
      final k = n ~/ 1000;
      final rem = n % 1000;
      final kPart = '${numberToEnglishWords(k)} thousand';
      if (rem == 0) return kPart;
      final connector = rem < 100 ? ' and ' : ' ';
      return '$kPart$connector${numberToEnglishWords(rem)}';
    }
    return n.toString();
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Format denomination integer for English speech (e.g. `200` -> `200`, `2000` -> `2,000`).
  static String _formatEnglishDenomDigits(int value) {
    if (value >= 1000) {
      final s = value.toString();
      if (s.length == 4) return '${s[0]},${s.substring(1)}';
    }
    return value.toString();
  }

  /// Format a single grouped denomination phrase in English, e.g.
  /// `(INR_200, 200, 2)` -> `"two 200-rupee notes"`.
  static String formatEnglishGroup(String denomination, int value, int count) {
    final bool isCoin = denomination.toUpperCase().contains('COIN');
    final String noun = isCoin
        ? (count == 1 ? 'coin' : 'coins')
        : (count == 1 ? 'note' : 'notes');
    final String countWords = numberToEnglishWords(count);
    final String denomStr = _formatEnglishDenomDigits(value);
    return '$countWords $denomStr-rupee $noun';
  }

  static String _joinEnglishList(List<String> items) {
    if (items.isEmpty) return '';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} and ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')}, and ${items.last}';
  }

  static ({Map<String, int> counts, Map<String, int> values}) _aggregate(
    List<CurrencyDetection> detections,
  ) {
    final counts = <String, int>{};
    final values = <String, int>{};
    for (final d in detections) {
      counts[d.denomination] = (counts[d.denomination] ?? 0) + 1;
      values[d.denomination] = d.value;
    }
    return (counts: counts, values: values);
  }

  /// Build natural, unambiguous English speech for a [CurrencySafetyAssessment].
  static String formatAssessmentEnglish(CurrencySafetyAssessment assessment) {
    final bool isInvalid = assessment.reasons.contains('INVALID_CURRENCY_DETECTED') ||
        assessment.reasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        assessment.spokenMessage == 'Invalid' ||
        assessment.screenedDetections.any((d) => d.denomination == 'INVALID');
    final bool isUnrecognised = assessment.reasons.contains('UNRECOGNISED_CURRENCY') ||
        assessment.reasons.contains('IDENTITY_UNKNOWN') ||
        assessment.spokenMessage.contains('Unrecognised') ||
        assessment.screenedDetections.any((d) => d.denomination == 'UNRECOGNISED');

    if (isInvalid) {
      return 'Invalid';
    }

    switch (assessment.status) {
      case AnnouncementSafetyStatus.empty:
        if (isUnrecognised) {
          return 'Unrecognised currency. Hold steady and try again.';
        }
        return 'No currency detected. Please hold closer.';
      case AnnouncementSafetyStatus.conflictingOrUncertain:
        if (isUnrecognised) {
          return 'Unrecognised currency. Hold steady and try again.';
        }
        if (assessment.spokenMessage.isNotEmpty) {
          return assessment.spokenMessage;
        }
        if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
            assessment.reasons.contains('UNCERTAIN_COUNT')) {
          return 'Some notes are unclear or overlapping. Please spread them apart and try again.';
        }
        return 'Difficult to denominate. Please adjust lighting or angle and try again.';
      case AnnouncementSafetyStatus.tentativeSingle:
        if (isUnrecognised) {
          return 'Unrecognised currency. Hold steady and try again.';
        }
        if (assessment.spokenMessage.isNotEmpty) {
          return assessment.spokenMessage;
        }
        return 'Difficult to denominate. Please hold steady in better light.';
      case AnnouncementSafetyStatus.confirmedSingle:
        final d = assessment.screenedDetections.first;
        return '${_capitalize(formatEnglishGroup(d.denomination, d.value, 1))}.';
      case AnnouncementSafetyStatus.confirmedMultiple:
        final agg = _aggregate(assessment.screenedDetections);
        final parts = <String>[];
        agg.counts.forEach((denom, count) {
          final val = agg.values[denom] ?? 0;
          parts.add(formatEnglishGroup(denom, val, count));
        });
        final total = assessment.confirmedTotalRupees ?? assessment.visibleDetectedSumRupees;
        final totalWords = numberToEnglishWords(total);
        final rupeeWord = total == 1 ? 'rupee' : 'rupees';
        return '${_capitalize(_joinEnglishList(parts))}. Total $totalWords $rupeeWord.';
    }
  }

  // ---------------------------------------------------------------------------
  // HINDI (hi-IN) NUMBER & CURRENCY NORMALIZATION
  // ---------------------------------------------------------------------------

  static const Map<int, String> _hiExact = {
    0: 'शून्य',
    1: 'एक',
    2: 'दो',
    3: 'तीन',
    4: 'चार',
    5: 'पाँच',
    6: 'छह',
    7: 'सात',
    8: 'आठ',
    9: 'नौ',
    10: 'दस',
    11: 'ग्यारह',
    12: 'बारह',
    13: 'तेरह',
    14: 'चौदह',
    15: 'पंद्रह',
    16: 'सोलह',
    17: 'सत्रह',
    18: 'अठारह',
    19: 'उन्नीस',
    20: 'बीस',
    21: 'इक्कीस',
    22: 'बाईस',
    23: 'तेईस',
    24: 'चौबीस',
    25: 'पच्चीस',
    26: 'छब्बीस',
    27: 'सत्ताईस',
    28: 'अट्ठाईस',
    29: 'उनतीस',
    30: 'तीस',
    31: 'इकतीस',
    32: 'बत्तीस',
    33: 'तैंतीस',
    34: 'चौंतीस',
    35: 'पैंतीस',
    36: 'छत्तीस',
    37: 'सैंतीस',
    38: 'अड़तीस',
    39: 'उनतालीस',
    40: 'चालीस',
    41: 'इकतालीस',
    42: 'बयालीस',
    43: 'तैंतालीस',
    44: 'चवालीस',
    45: 'पैंतालीस',
    46: 'छियालीस',
    47: 'सैंतालीस',
    48: 'अड़तालीस',
    49: 'उनचास',
    50: 'पचास',
    51: 'इक्यावन',
    52: 'बावन',
    53: 'तिरपन',
    54: 'चौवन',
    55: 'पचपन',
    56: 'छप्पन',
    57: 'सत्तावन',
    58: 'अट्ठावन',
    59: 'उनसठ',
    60: 'साठ',
    61: 'इकसठ',
    62: 'बासठ',
    63: 'तिरसठ',
    64: 'चौंसठ',
    65: 'पैंसठ',
    66: 'छियासठ',
    67: 'सड़सठ',
    68: 'अड़सठ',
    69: 'उनहत्तर',
    70: 'सत्तर',
    71: 'इकहत्तर',
    72: 'बहत्तर',
    73: 'तिहत्तर',
    74: 'चौहत्तर',
    75: 'पचहत्तर',
    76: 'छिहत्तर',
    77: 'सतहत्तर',
    78: 'अठहत्तर',
    79: 'उनासी',
    80: 'अस्सी',
    81: 'इक्यासी',
    82: 'बयासी',
    83: 'तिरासी',
    84: 'चौरासी',
    85: 'पचासी',
    86: 'छियासी',
    87: 'सत्तासी',
    88: 'अट्ठासी',
    89: 'नवासी',
    90: 'नब्बे',
    91: 'इक्यानवे',
    92: 'बानवे',
    93: 'तिरानवे',
    94: 'चौरानवे',
    95: 'पचानवे',
    96: 'छियानवे',
    97: 'सत्तानवे',
    98: 'अट्ठानवे',
    99: 'निन्यानवे',
  };

  /// Convert a non-negative integer [n] (0..9,99,999) into natural Hindi words.
  static String numberToHindiWords(int n) {
    if (n < 0) return 'माइनस ${numberToHindiWords(-n)}';
    if (n < 100) return _hiExact[n]!;
    if (n < 1000) {
      final h = n ~/ 100;
      final rem = n % 100;
      final hWord = '${_hiExact[h]} सौ';
      return rem == 0 ? hWord : '$hWord ${numberToHindiWords(rem)}';
    }
    if (n < 100000) {
      final k = n ~/ 1000;
      final rem = n % 1000;
      final kWord = '${numberToHindiWords(k)} हज़ार';
      return rem == 0 ? kWord : '$kWord ${numberToHindiWords(rem)}';
    }
    final lakh = n ~/ 100000;
    final rem = n % 100000;
    final lWord = '${numberToHindiWords(lakh)} लाख';
    return rem == 0 ? lWord : '$lWord ${numberToHindiWords(rem)}';
  }

  /// Format a single grouped denomination phrase in Hindi using words for both
  /// count and denomination so Hindi TTS never merges numbers.
  static String formatHindiGroup(String denomination, int value, int count) {
    final bool isCoin = denomination.toUpperCase().contains('COIN');
    final String countWord = numberToHindiWords(count);
    final String valWords = numberToHindiWords(value);
    if (isCoin) {
      return count == 1
          ? '$countWord $valWords रुपये का सिक्का'
          : '$countWord $valWords रुपये के सिक्के';
    }
    return count == 1
        ? '$countWord $valWords रुपये का नोट'
        : '$countWord $valWords रुपये के नोट';
  }

  /// Build natural Hindi speech for a [CurrencySafetyAssessment].
  static String formatAssessmentHindi(CurrencySafetyAssessment assessment) {
    final bool isInvalid = assessment.reasons.contains('INVALID_CURRENCY_DETECTED') ||
        assessment.reasons.contains('FOREIGN_CURRENCY_DETECTED') ||
        assessment.spokenMessage == 'Invalid' ||
        assessment.screenedDetections.any((d) => d.denomination == 'INVALID');
    final bool isUnrecognised = assessment.reasons.contains('UNRECOGNISED_CURRENCY') ||
        assessment.reasons.contains('IDENTITY_UNKNOWN') ||
        assessment.spokenMessage.contains('Unrecognised') ||
        assessment.screenedDetections.any((d) => d.denomination == 'UNRECOGNISED');

    if (isInvalid) {
      return 'अमान्य';
    }

    switch (assessment.status) {
      case AnnouncementSafetyStatus.empty:
        if (isUnrecognised) {
          return 'अपरिचित मुद्रा। स्थिर रखें और फिर प्रयास करें।';
        }
        return 'कोई मुद्रा नहीं मिली। कृपया पास लाएँ।';
      case AnnouncementSafetyStatus.conflictingOrUncertain:
        if (isUnrecognised) {
          return 'अपरिचित मुद्रा। स्थिर रखें और फिर प्रयास करें।';
        }
        if (assessment.reasons.contains('MERGED_BOX_SUSPECTED') ||
            assessment.reasons.contains('UNCERTAIN_COUNT')) {
          return 'कुछ नोट स्पष्ट नहीं हैं या एक दूसरे के ऊपर हैं। कृपया अलग करके फिर प्रयास करें।';
        }
        return 'मूल्य स्पष्ट नहीं है। कृपया रोशनी या कोण ठीक करके फिर प्रयास करें।';
      case AnnouncementSafetyStatus.tentativeSingle:
        if (isUnrecognised) {
          return 'अपरिचित मुद्रा। स्थिर रखें और फिर प्रयास करें।';
        }
        final d = assessment.screenedDetections.first;
        return '${formatHindiGroup(d.denomination, d.value, 1)}।';
      case AnnouncementSafetyStatus.confirmedSingle:
        final d = assessment.screenedDetections.first;
        return '${formatHindiGroup(d.denomination, d.value, 1)}।';
      case AnnouncementSafetyStatus.confirmedMultiple:
        final agg = _aggregate(assessment.screenedDetections);
        final parts = <String>[];
        agg.counts.forEach((denom, count) {
          final val = agg.values[denom] ?? 0;
          parts.add(formatHindiGroup(denom, val, count));
        });
        final joined = parts.length == 2
            ? '${parts[0]} और ${parts[1]}'
            : parts.join(', ');
        final total = assessment.confirmedTotalRupees ?? assessment.visibleDetectedSumRupees;
        final totalWords = numberToHindiWords(total);
        final rupeeWord = total == 1 ? 'रुपया' : 'रुपये';
        return '$joined। कुल $totalWords $rupeeWord।';
    }
  }

  /// Format [assessment] in the requested currency speech [language]
  /// (`'en-IN'`, `'kn-IN'`, `'hi-IN'`, or `'ceb-PH'`).
  static String formatAssessment(
    CurrencySafetyAssessment assessment, {
    required String language,
  }) {
    switch (language) {
      case 'kn-IN':
        return KannadaNumberNormalizer.formatAssessmentKannada(assessment);
      case 'hi-IN':
        return formatAssessmentHindi(assessment);
      case 'ceb-PH':
        return BisayaNumberNormalizer.formatAssessmentBisaya(assessment);
      case 'en-IN':
      default:
        return formatAssessmentEnglish(assessment);
    }
  }

  /// Empty-frame prompt for currency snapshot capture in [language].
  static String formatEmptyPrompt(String language) {
    switch (language) {
      case 'kn-IN':
        return 'ಹಣ ಕಂಡುಬಂದಿಲ್ಲ. ದಯವಿಟ್ಟು ಹತ್ತಿರ ಹಿಡಿಯಿರಿ.';
      case 'hi-IN':
        return 'कोई मुद्रा नहीं मिली। कृपया पास लाएँ।';
      case 'ceb-PH':
        return 'Walay kwarta nga nakita. Palihug ipaduol pa gamay.';
      case 'en-IN':
      default:
        return 'No currency detected. Please hold closer.';
    }
  }
}
