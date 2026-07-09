import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/models/client.dart';

void main() {
  group('Wireless client metrics', () {
    test('parses signal-to-noise ratio and link speed from lease details', () {
      final client = Client.fromLease({
        'macaddr': 'aa:bb:cc:11:22:33',
        'ipaddr': '192.168.1.100',
        'hostname': 'iPhone-John',
        'signal': -45,
        'noise': -95,
        'rx_rate': 144400,
        'tx_rate': 866700,
      });

      expect(client.connectionType, ConnectionType.wireless);
      expect(client.signalToNoiseRatio, 50);
      expect(client.formattedSignalToNoiseRatio, '50 dB');
      expect(client.formattedLinkSpeed, 'Rx 144.4 Mbps / Tx 866.7 Mbps');
    });

    test('parses nested iwinfo rate maps', () {
      final client = Client.fromWirelessStation(
        'AA:BB:CC:DD:EE:FF',
        stationDetails: {
          'signal': -56,
          'noise': -97,
          'rx': {'rate': 585000},
          'tx': {'rate': 390000},
        },
      );

      expect(client.signalToNoiseRatio, 41);
      expect(client.formattedLinkSpeed, 'Rx 585 Mbps / Tx 390 Mbps');
    });

    test('formats high kbit/s link rates as gigabit-class Mbps', () {
      final client = Client.fromWirelessStation(
        'AA:BB:CC:DD:EE:FF',
        stationDetails: {
          'rx_rate': 1200000,
          'tx_rate': 866700,
        },
      );

      expect(client.formattedLinkSpeed, 'Rx 1200 Mbps / Tx 866.7 Mbps');
    });

    test('always shows both directions when rx and tx match', () {
      final client = Client.fromWirelessStation(
        'AA:BB:CC:DD:EE:FF',
        stationDetails: {
          'rx_rate': 866700,
          'tx_rate': 866700,
        },
      );

      expect(client.formattedLinkSpeed, 'Rx 866.7 Mbps / Tx 866.7 Mbps');
    });

    test('shows unavailable metrics as N/A', () {
      final client = Client.fromWirelessStation('AA:BB:CC:DD:EE:FF');

      expect(client.formattedSignalToNoiseRatio, 'N/A');
      expect(client.formattedLinkSpeed, 'N/A');
    });
  });
}
