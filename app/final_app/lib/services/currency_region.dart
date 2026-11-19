import 'currency_model_service.dart';

/// Explicit currency region selected by the Currency Voice language.
///
/// Mapping:
/// - `en-IN`, `kn-IN`, `hi-IN` -> [CurrencyRegion.inr] (`₹`, Indian Rupee)
/// - `ceb-PH`                  -> [CurrencyRegion.php] (`₱`, Philippine Peso)
enum CurrencyRegion { inr, php }

/// Resolve the active [CurrencyRegion] from a currency language code.
CurrencyRegion currencyRegionForLanguage(String languageCode) {
  return languageCode == 'ceb-PH' ? CurrencyRegion.php : CurrencyRegion.inr;
}

/// Currency symbol for [region].
String currencySymbolForRegion(CurrencyRegion region) {
  return region == CurrencyRegion.php ? '₱' : '₹';
}

/// Canonical allowlist of Indian Rupee (INR) classes.
const Set<String> kInrDenominationAllowlist = {
  'INR_10',
  'INR_20',
  'INR_50',
  'INR_100',
  'INR_200',
  'INR_500',
  'INR_2000',
  'INR_1_COIN',
  'INR_2_COIN',
  'INR_5_COIN',
  'INR_10_COIN',
  'COIN_1',
  'COIN_2',
  'COIN_5',
  'COIN_10',
};

/// Canonical allowlist of Philippine Peso (PHP) classes (paper NGC, polymer FPP,
/// circulating coins, and demonetized NDS warning class).
const Set<String> kPhpDenominationAllowlist = {
  'PHP_PAPER_20',
  'PHP_PAPER_50',
  'PHP_PAPER_100',
  'PHP_PAPER_200',
  'PHP_PAPER_500',
  'PHP_PAPER_1000',
  'PHP_POLYMER_50',
  'PHP_POLYMER_100',
  'PHP_POLYMER_500',
  'PHP_POLYMER_1000',
  'PHP_OLD_DEMONETIZED',
  'PHP_COIN_001_SENTIMO',
  'PHP_COIN_005_SENTIMO',
  'PHP_COIN_010_SENTIMO',
  'PHP_COIN_025_SENTIMO',
  'PHP_COIN_1_PISO',
  'PHP_COIN_5_PISO',
  'PHP_COIN_10_PISO',
  'PHP_COIN_20_PISO',
};

/// Exact monetary value in integer **sentimo** (`100 sentimo = ₱1.00`) for
/// every supported Philippine Peso class. Demonetized notes have value `0`.
const Map<String, int> kPhpSentimoValues = {
  'PHP_COIN_001_SENTIMO': 1,
  'PHP_COIN_005_SENTIMO': 5,
  'PHP_COIN_010_SENTIMO': 10,
  'PHP_COIN_025_SENTIMO': 25,
  'PHP_COIN_1_PISO': 100,
  'PHP_COIN_5_PISO': 500,
  'PHP_COIN_10_PISO': 1000,
  'PHP_COIN_20_PISO': 2000,
  'PHP_PAPER_20': 2000,
  'PHP_PAPER_50': 5000,
  'PHP_POLYMER_50': 5000,
  'PHP_PAPER_100': 10000,
  'PHP_POLYMER_100': 10000,
  'PHP_PAPER_200': 20000,
  'PHP_PAPER_500': 50000,
  'PHP_POLYMER_500': 50000,
  'PHP_PAPER_1000': 100000,
  'PHP_POLYMER_1000': 100000,
  'PHP_OLD_DEMONETIZED': 0,
};

/// Strict region allowlist guard: returns `true` iff [denomination] belongs
/// exclusively to [region].
bool isDenominationAllowedForRegion(String denomination, CurrencyRegion region) {
  final upper = denomination.toUpperCase();
  if (region == CurrencyRegion.php) {
    return kPhpDenominationAllowlist.contains(upper);
  }
  return kInrDenominationAllowlist.contains(upper);
}

/// Filter raw [detections] so cross-currency objects from the unselected region
/// can never enter tracking, aggregation, or speech.
List<CurrencyDetection> filterDetectionsForRegion(
  List<CurrencyDetection> detections,
  CurrencyRegion region,
) {
  return detections
      .where((d) => isDenominationAllowedForRegion(d.denomination, region))
      .toList(growable: false);
}

/// Generation-guarded currency region state controller.
/// Every INR <-> PHP transition increments [regionEpoch] so in-flight inference
/// results from the previous region are discarded before tracking or speech.
class CurrencyRegionController {
  CurrencyRegionController({String initialLanguage = 'en-IN'})
    : _region = currencyRegionForLanguage(initialLanguage);

  CurrencyRegion _region;
  int _regionEpoch = 0;

  CurrencyRegion get region => _region;
  int get regionEpoch => _regionEpoch;
  String get symbol => currencySymbolForRegion(_region);

  /// Update region from [languageCode]. Returns `true` if the region changed
  /// (incrementing [regionEpoch]).
  bool updateForLanguage(String languageCode) {
    final next = currencyRegionForLanguage(languageCode);
    if (next == _region) return false;
    _region = next;
    _regionEpoch++;
    return true;
  }

  /// Returns `true` iff an async inference result produced at [capturedEpoch]
  /// for [capturedRegion] is still valid.
  bool isResultCurrent({
    required int capturedEpoch,
    required CurrencyRegion capturedRegion,
  }) {
    return capturedEpoch == _regionEpoch && capturedRegion == _region;
  }
}
