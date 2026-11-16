import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assistant/services/speech_service.dart';

void main() {
  group('Phase 5.4.2 Voice Selection Restoration', () {
    test('en-IN selects en-in-* over en-us-* regardless of list order', () {
      final voices = [
        {'name': 'en-us-x-tpc-local', 'locale': 'en-US', 'network_required': 'false'},
        {'name': 'en-in-x-end-local', 'locale': 'en-IN', 'network_required': 'false'},
        {'name': 'en-in-x-enc-local', 'locale': 'en-IN', 'network_required': 'false'},
      ];

      final picked = SpeechService.selectBestVoice('en-IN', voices);
      expect(picked?['name'], 'en-in-x-enc-local');
      expect(picked?['locale'], 'en-IN');
    });

    test('kn-IN and hi-IN select kn-in-x-knd-local and hi-in-x-hia-local over alternate variants', () {
      final voices = [
        {'name': 'kn-in-x-knc-local', 'locale': 'kn-IN', 'network_required': 'false'},
        {'name': 'kn-in-x-knd-local', 'locale': 'kn-IN', 'network_required': 'false'},
        {'name': 'hi-in-x-hie-local', 'locale': 'hi-IN', 'network_required': 'false'},
        {'name': 'hi-in-x-hia-local', 'locale': 'hi-IN', 'network_required': 'false'},
      ];

      expect(SpeechService.selectBestVoice('kn-IN', voices)?['name'], 'kn-in-x-knd-local');
      expect(SpeechService.selectBestVoice('hi-IN', voices)?['name'], 'hi-in-x-hia-local');
    });

    test('Falls back gracefully on devices with different manufacturer voice IDs', () {
      final voices = [
        {'name': 'oem-kn-network', 'locale': 'kn-IN', 'network_required': 'true'},
        {'name': 'oem-kn-offline-local', 'locale': 'kn-IN', 'network_required': 'false'},
      ];

      expect(SpeechService.selectBestVoice('kn-IN', voices)?['name'], 'oem-kn-offline-local');
    });
  });
}
