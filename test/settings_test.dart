import 'package:flutter_test/flutter_test.dart';
import 'package:nightdrop/src/settings.dart';

void main() {
  group('validateServerUrl', () {
    test('http はローカルネットワークの宛先だけ許可する', () {
      for (final url in [
        'http://192.168.0.10:5000',
        'http://10.0.0.5:5000',
        'http://172.16.0.1',
        'http://172.31.255.255:5000/',
        'http://127.0.0.1:5000',
        'http://raspberrypi.local:5000',
      ]) {
        expect(validateServerUrl(url), isNull, reason: url);
      }
      for (final url in ['http://172.32.0.1', 'http://8.8.8.8', 'http://example.com', 'http://[::1]:5000']) {
        expect(validateServerUrl(url), isNotNull, reason: url);
      }
    });

    test('https は宛先を問わない', () {
      expect(validateServerUrl('https://example.com'), isNull);
    });

    test('形式が不正なものは拒否する', () {
      for (final url in ['', '192.168.0.10:5000', 'ftp://192.168.0.10', 'http://']) {
        expect(validateServerUrl(url), isNotNull, reason: url);
      }
    });
  });
}
