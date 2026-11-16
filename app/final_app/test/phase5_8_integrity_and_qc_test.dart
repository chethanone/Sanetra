import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vision_assistant/services/ocr/ocr_model_loader.dart';
import 'package:vision_assistant/services/ocr/ocr_preprocessing.dart';

void main() {
  group('Phase 5.8 Model Integrity & Preprocessing', () {
    test('sha256Hex matches standard NIST vectors', () {
      expect(
        sha256Hex(Uint8List(0)),
        'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855',
      );
      expect(
        sha256Hex(Uint8List.fromList(utf8.encode('abc'))),
        'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
      );
    });

    test('prepareArjunaKannadaTensor produces H=32 white-padded bucket tensor', () {
      final image = img.Image(width: 100, height: 40);
      img.fill(image, color: img.ColorRgb8(0, 0, 0));
      final prep = OcrPreprocessing.prepareArjunaKannadaTensor(image);
      expect(prep.targetHeight, 32);
      expect(prep.targetWidth, 80); // round(100 * 32 / 40) = 80
      expect(prep.tensorWidth, 96); // smallest bucket >= ceil(2.5*32/4)*4 = 80 -> 96
      expect(prep.tensorData.length, 3 * 32 * 96);
      // Active black pixel at (0,0) -> -1.0
      expect(prep.tensorData[0], closeTo(-1.0, 1e-4));
      // White right-padding at x=90 -> +1.0
      expect(prep.tensorData[90], closeTo(1.0, 1e-4));
    });

    test('Bundled Kannada and Hindi dictionaries are valid and non-empty', () {
      final kaRaw = File('assets/models/ocr/kannada/character_dict_ka.json').readAsStringSync();
      final kaDict = (jsonDecode(kaRaw) as List).cast<String>();
      expect(kaDict.length, 163);
      expect(kaDict.contains('ಅ'), isTrue);

      final hiRaw = File('assets/models/ocr/devanagari/character_dict_hi.json').readAsStringSync();
      final hiDict = (jsonDecode(hiRaw) as List).cast<String>();
      expect(hiDict.length, 568);
      expect(hiDict[1], '"');
    });
  });
}
