import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/utils/logger.dart';

void main() {
  group('Logger', () {
    tearDown(Logger.clear);

    test('exports captured session log entries', () {
      Logger.clear();
      Logger.info('Firewall rule failed');

      expect(Logger.exportLog(), contains('Firewall rule failed'));
    });

    test('redacts obvious secrets from exported entries', () {
      Logger.clear();
      Logger.error(
        'Login failed luci_password=secret password=another token=abc123',
      );

      final log = Logger.exportLog();

      expect(log, isNot(contains('secret')));
      expect(log, isNot(contains('another')));
      expect(log, isNot(contains('abc123')));
      expect(log, contains('<redacted>'));
    });
  });
}
