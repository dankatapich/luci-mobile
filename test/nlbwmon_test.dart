import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/models/nlbwmon.dart';

void main() {
  group('NlbwmonSnapshot', () {
    test('aggregates host and protocol usage from action data', () {
      final snapshot = NlbwmonSnapshot.fromActionData(
        {
          'columns': [
            'family',
            'mac',
            'ip',
            'layer7',
            'conns',
            'rx_bytes',
            'rx_pkts',
            'tx_bytes',
            'tx_pkts',
          ],
          'data': [
            [
              6,
              'aa:bb:cc:11:22:33',
              'fd00::10',
              'dns',
              3,
              200,
              5,
              50,
              2,
            ],
            [
              4,
              'aa:bb:cc:11:22:33',
              '192.168.1.10',
              'https',
              10,
              1000,
              20,
              500,
              10,
            ],
            [
              4,
              '00:00:00:00:00:00',
              '192.168.1.20',
              '',
              2,
              300,
              4,
              100,
              1,
            ],
          ],
        },
        periods: const ['2026-07-01'],
      );

      expect(snapshot.periods, ['2026-07-01']);
      expect(snapshot.hostCount, 2);
      expect(snapshot.totalRxBytes, 1500);
      expect(snapshot.totalTxBytes, 650);
      expect(snapshot.totalConnections, 15);

      expect(snapshot.hosts.first.macAddress, 'AA:BB:CC:11:22:33');
      expect(snapshot.hosts.first.ipAddress, '192.168.1.10');
      expect(snapshot.hosts.first.rxBytes, 1200);
      expect(snapshot.hosts.first.txBytes, 550);

      expect(snapshot.protocols.map((entry) => entry.label), [
        'https',
        'Other',
        'dns',
      ]);
    });

    test('rejects malformed action data', () {
      expect(
        () => NlbwmonSnapshot.fromActionData({'columns': []}),
        throwsFormatException,
      );
    });
  });
}
