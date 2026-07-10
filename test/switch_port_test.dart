import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/models/switch_port.dart';

void main() {
  group('Switch port parsing', () {
    test('labels board ports and hides CPU ports from visible ports', () {
      final groups = buildSwitchPortGroups(
        boardJson: {
          'switch': {
            'switch0': {
              'ports': [
                {'num': 6, 'device': 'eth0', 'need_tag': false},
                {'num': 1, 'role': 'lan', 'index': 1},
                {'num': 2, 'role': 'lan', 'index': 2},
                {'num': 0, 'role': 'wan'},
              ],
            },
          },
        },
        uciNetworkConfig: {
          'values': {
            'cfg01': {
              '.type': 'switch',
              'name': 'switch0',
            },
          },
        },
        portStatesBySwitch: {
          'switch0': {
            'result': [
              {'port': 6, 'link': true, 'speed': 1000, 'duplex': true},
              {'port': 1, 'link': true, 'speed': 100, 'duplex': true},
              {'port': 2, 'link': false},
              {'port': 0, 'link': false},
            ],
          },
        },
        featuresBySwitch: {
          'switch0': {'switch_title': 'rt305x-esw'},
        },
      );

      expect(groups, hasLength(1));
      expect(groups.first.displayName, 'switch0 (rt305x-esw)');
      expect(groups.first.ports.map((port) => port.label), [
        'CPU (eth0)',
        'LAN 1',
        'LAN 2',
        'WAN',
      ]);
      expect(groups.first.visiblePorts.map((port) => port.label), [
        'LAN 1',
        'LAN 2',
        'WAN',
      ]);
      expect(groups.first.connectedPortCount, 1);
      expect(
        groups.first.visiblePorts.first.statusText,
        '100baseT full-duplex',
      );
    });

    test('falls back to UCI switch names and generic port labels', () {
      final groups = buildSwitchPortGroups(
        boardJson: {},
        uciNetworkConfig: {
          'values': {
            '@switch[0]': {
              '.type': 'switch',
              'name': 'switch0',
            },
          },
        },
        portStatesBySwitch: {
          'switch0': [
            {'port': 0, 'link': false},
            {'port': 1, 'link': true, 'speed': '1000', 'duplex': '1'},
          ],
        },
        featuresBySwitch: {},
      );

      expect(groups, hasLength(1));
      expect(groups.first.visiblePorts.map((port) => port.label), [
        'Port 1',
        'Port 2',
      ]);
      expect(
        groups.first.visiblePorts.last.statusText,
        '1000baseT full-duplex',
      );
    });

    test('extracts switch names from board JSON and UCI config', () {
      final names = extractSwitchNamesFromData(
        boardJson: {
          'switch': {
            'switch0': {},
          },
        },
        uciNetworkConfig: {
          'network': {
            'cfg01': {
              '.type': 'switch',
              'name': 'switch1',
            },
          },
        },
      );

      expect(names, {'switch0', 'switch1'});
    });

    test('builds direct ethernet ports from builtin port status', () {
      final group = buildDirectPortGroup(
        builtinPorts: {
          'result': [
            {'role': 'lan', 'device': 'lan1'},
            {'role': 'lan', 'device': 'lan2'},
            {'role': 'wan', 'device': 'wan'},
          ],
        },
        boardJson: {},
        deviceStatuses: {
          'lan1': {'carrier': true, 'speed': 1000, 'duplex': 'full'},
          'lan2': {'carrier': true, 'speed': 100, 'duplex': 'full'},
          'wan': {'carrier': false},
        },
      );

      expect(group, isNotNull);
      expect(group!.displayName, 'Ethernet');
      expect(group.visiblePorts.map((port) => port.label), [
        'lan1',
        'lan2',
        'wan',
      ]);
      expect(group.connectedPortCount, 2);
      expect(group.visiblePorts.first.statusText, '1000baseT full-duplex');
      expect(group.visiblePorts.last.statusText, 'No link');
    });

    test('builds direct ethernet status from network device link cache', () {
      final group = buildDirectPortGroup(
        builtinPorts: {
          'result': [
            {'role': 'lan', 'device': 'lan1'},
            {'role': 'lan', 'device': 'lan2'},
            {'role': 'wan', 'device': 'wan'},
          ],
        },
        boardJson: {},
        deviceStatuses: const <String, dynamic>{},
        networkDevices: {
          'lan1': {
            'link': {'carrier': true, 'speed': 1000, 'duplex': 'full'},
          },
          'lan2': {
            'link': {'carrier': true, 'speed': 100, 'duplex': 'full'},
          },
          'wan': {
            'link': {'carrier': false},
          },
        },
      );

      expect(group, isNotNull);
      expect(group!.connectedPortCount, 2);
      expect(group.visiblePorts.first.statusText, '1000baseT full-duplex');
      expect(group.visiblePorts[1].statusText, '100baseT full-duplex');
      expect(group.visiblePorts.last.statusText, 'No link');
    });

    test('falls back to board network ports for direct ethernet devices', () {
      final names = extractDirectPortNamesFromData(
        builtinPorts: {},
        boardJson: {
          'network': {
            'lan': {
              'ports': ['lan2', 'lan1'],
            },
            'wan': {
              'device': 'wan',
            },
          },
        },
      );

      expect(names, {'lan1', 'lan2', 'wan'});
    });
  });
}
