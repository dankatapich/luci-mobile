import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/models/client.dart';

void main() {
  group('Client block status', () {
    test('parses blocked state and router metadata from lease', () {
      final client = Client.fromLease({
        'macaddr': '24:e4:ce:7c:50:56',
        'ipaddr': '192.168.200.21',
        'hostname': 'Android-TV-Panasonic',
        'isBlocked': true,
        'routerId': 'router-1',
        'routerName': 'Office Router',
      });

      expect(client.isBlocked, isTrue);
      expect(client.routerId, 'router-1');
      expect(client.routerName, 'Office Router');
    });

    test('creates offline blocked client from firewall rule', () {
      final client = Client.blocked(
        macAddress: '24:E4:CE:7C:50:56',
        routerId: 'router-1',
        routerName: 'Office Router',
      );

      expect(client.hostname, 'Blocked Device');
      expect(client.ipAddress, 'N/A');
      expect(client.isBlocked, isTrue);
      expect(client.routerName, 'Office Router');
    });
  });
}
