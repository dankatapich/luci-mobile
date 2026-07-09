import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/services/api_service.dart';

void main() {
  group('Wireless interface client scanning', () {
    test('includes AP mode interfaces', () {
      final shouldScan = shouldFetchAssociatedStationsForWirelessInterface({
        'ifname': 'wlan0',
        'config': {'mode': 'ap'},
        'iwinfo': {'mode': 'Master'},
      });

      expect(shouldScan, isTrue);
    });

    test('excludes STA mode uplink interfaces', () {
      final shouldScan = shouldFetchAssociatedStationsForWirelessInterface({
        'ifname': 'wlan1',
        'config': {'mode': 'sta'},
        'iwinfo': {'mode': 'Client'},
      });

      expect(shouldScan, isFalse);
    });

    test('excludes explicit non-client non-AP modes', () {
      final shouldScan = shouldFetchAssociatedStationsForWirelessInterface({
        'ifname': 'mesh0',
        'config': {'mode': 'mesh'},
      });

      expect(shouldScan, isFalse);
    });

    test('keeps scanning when older LuCI responses omit mode data', () {
      final shouldScan = shouldFetchAssociatedStationsForWirelessInterface({
        'ifname': 'wlan0',
      });

      expect(shouldScan, isTrue);
    });
  });
}
