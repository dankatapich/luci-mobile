class SwitchPortGroup {
  final String switchName;
  final String? title;
  final List<SwitchPort> ports;

  const SwitchPortGroup({
    required this.switchName,
    required this.ports,
    this.title,
  });

  List<SwitchPort> get visiblePorts =>
      ports.where((port) => !port.isCpu).toList(growable: false);

  int get connectedPortCount =>
      visiblePorts.where((port) => port.isConnected).length;

  String get displayName {
    final cleanTitle = title?.trim();
    if (cleanTitle == null || cleanTitle.isEmpty) return switchName;
    return '$switchName ($cleanTitle)';
  }

  String get summary {
    final total = visiblePorts.length;
    final connected = connectedPortCount;
    if (total == 1) {
      return connected == 1 ? '1 port connected' : 'No ports connected';
    }
    return '$connected of $total ports connected';
  }
}

class SwitchPort {
  final String switchName;
  final int number;
  final String label;
  final bool isCpu;
  final bool hasStatus;
  final bool link;
  final int? speed;
  final bool? duplex;
  final String? device;

  const SwitchPort({
    required this.switchName,
    required this.number,
    required this.label,
    required this.isCpu,
    required this.hasStatus,
    required this.link,
    this.speed,
    this.duplex,
    this.device,
  });

  bool get isConnected => hasStatus && link;

  String get statusText {
    if (!hasStatus) return 'Unknown';
    if (!link) return 'No link';

    final parts = <String>[];
    if (speed != null && speed! > 0) {
      parts.add('${speed}baseT');
    } else {
      parts.add('Connected');
    }

    if (duplex != null) {
      parts.add(duplex! ? 'full-duplex' : 'half-duplex');
    }

    return parts.join(' ');
  }
}

List<SwitchPortGroup> buildSwitchPortGroups({
  required dynamic boardJson,
  required dynamic uciNetworkConfig,
  required Map<String, dynamic> portStatesBySwitch,
  required Map<String, dynamic> featuresBySwitch,
}) {
  final topologies = _parseBoardTopologies(boardJson);
  final switchNames = extractSwitchNamesFromData(
    boardJson: boardJson,
    uciNetworkConfig: uciNetworkConfig,
  )
    ..addAll(portStatesBySwitch.keys)
    ..addAll(featuresBySwitch.keys);

  final groups = <SwitchPortGroup>[];
  final sortedSwitchNames = switchNames.toList()..sort();

  for (final switchName in sortedSwitchNames) {
    final statusByPort = _parsePortStates(portStatesBySwitch[switchName]);
    final specs = <_SwitchPortSpec>[
      ...?topologies[switchName],
    ];

    if (specs.isEmpty && statusByPort.isNotEmpty) {
      final sortedPorts = statusByPort.keys.toList()..sort();
      for (final port in sortedPorts) {
        specs.add(
          _SwitchPortSpec(
            number: port,
            role: 'port',
            label: 'Port ${port + 1}',
            isCpu: false,
          ),
        );
      }
    }

    final knownPorts = specs.map((spec) => spec.number).toSet();
    final extraPorts = statusByPort.keys
        .where((port) => !knownPorts.contains(port))
        .toList()
      ..sort();
    for (final port in extraPorts) {
      specs.add(
        _SwitchPortSpec(
          number: port,
          role: 'port',
          label: 'Port ${port + 1}',
          isCpu: false,
        ),
      );
    }

    if (specs.isEmpty) continue;

    final ports = specs.map((spec) {
      final state = statusByPort[spec.number];
      return SwitchPort(
        switchName: switchName,
        number: spec.number,
        label: spec.label,
        isCpu: spec.isCpu,
        hasStatus: state != null,
        link: state?.link ?? false,
        speed: state?.speed,
        duplex: state?.duplex,
        device: spec.device,
      );
    }).toList(growable: false);

    groups.add(
      SwitchPortGroup(
        switchName: switchName,
        title: _switchTitle(featuresBySwitch[switchName]),
        ports: ports,
      ),
    );
  }

  return groups;
}

SwitchPortGroup? buildDirectPortGroup({
  required dynamic builtinPorts,
  required dynamic boardJson,
  required Map<String, dynamic> deviceStatuses,
  dynamic networkDevices,
}) {
  final specs = _parseDirectPortSpecs(
    builtinPorts: builtinPorts,
    boardJson: boardJson,
  );
  if (specs.isEmpty) return null;

  final ports = <SwitchPort>[];
  for (var index = 0; index < specs.length; index++) {
    final spec = specs[index];
    final status = _directDeviceStatus(
      spec.device,
      deviceStatuses: deviceStatuses,
      networkDevices: networkDevices,
    );
    final speed = _toInt(status['speed'] ?? status['link_speed']);
    final duplex = _toDuplexBool(status['duplex']);
    final parsedLink =
        _toBoolOrNull(status['carrier'] ?? status['link'] ?? status['up']);

    ports.add(
      SwitchPort(
        switchName: 'Ethernet',
        number: index,
        label: spec.label,
        isCpu: false,
        hasStatus: status.isNotEmpty,
        link: parsedLink ?? false,
        speed: speed,
        duplex: duplex,
        device: spec.device,
      ),
    );
  }

  return SwitchPortGroup(
    switchName: 'Ethernet',
    ports: ports,
  );
}

Set<String> extractSwitchNamesFromData({
  required dynamic boardJson,
  required dynamic uciNetworkConfig,
}) {
  final names = <String>{};
  final boardSwitches = _asMap(_asMap(boardJson)['switch']);
  names.addAll(boardSwitches.keys.map((key) => key.toString()));

  final uciValues = _uciValues(uciNetworkConfig);
  uciValues.forEach((key, value) {
    final section = _asMap(value);
    if (section['.type'] != 'switch') return;

    final name = _cleanString(section['name']) ??
        _cleanString(section['.name']) ??
        key.toString();
    if (name.isNotEmpty) names.add(name);
  });

  return names;
}

Set<String> extractDirectPortNamesFromData({
  required dynamic builtinPorts,
  required dynamic boardJson,
}) {
  return _parseDirectPortSpecs(
    builtinPorts: builtinPorts,
    boardJson: boardJson,
  ).map((spec) => spec.device).toSet();
}

Map<String, List<_SwitchPortSpec>> _parseBoardTopologies(dynamic boardJson) {
  final topologies = <String, List<_SwitchPortSpec>>{};
  final boardSwitches = _asMap(_asMap(boardJson)['switch']);

  boardSwitches.forEach((switchName, layoutValue) {
    final layout = _asMap(layoutValue);
    final rawPorts = layout['ports'];
    if (rawPorts is! List) return;

    final rawSpecs = <_RawSwitchPortSpec>[];
    final roleCounts = <String, int>{};

    for (final rawPort in rawPorts) {
      final port = _asMap(rawPort);
      final number = _toInt(port['num']);
      final device = _cleanString(port['device']);
      final role = _cleanString(port['role']) ?? (device == null ? null : 'cpu');
      if (number == null || role == null) continue;

      final normalizedRole = role.toLowerCase();
      roleCounts[normalizedRole] = (roleCounts[normalizedRole] ?? 0) + 1;
      rawSpecs.add(
        _RawSwitchPortSpec(
          number: number,
          role: normalizedRole,
          index: _toInt(port['index']) ?? number,
          device: device,
        ),
      );
    }

    rawSpecs.sort((a, b) {
      final roleCompare = a.role.compareTo(b.role);
      if (roleCompare != 0) return roleCompare;
      return a.index.compareTo(b.index);
    });

    final nextRoleIndex = <String, int>{};
    final specs = rawSpecs.map((spec) {
      final nextIndex = (nextRoleIndex[spec.role] ?? 0) + 1;
      nextRoleIndex[spec.role] = nextIndex;

      final isCpu = spec.role == 'cpu';
      final label = isCpu
          ? (spec.device == null ? 'CPU' : 'CPU (${spec.device})')
          : ((roleCounts[spec.role] ?? 0) > 1
              ? '${spec.role.toUpperCase()} $nextIndex'
              : spec.role.toUpperCase());

      return _SwitchPortSpec(
        number: spec.number,
        role: spec.role,
        label: label,
        isCpu: isCpu,
        device: spec.device,
      );
    }).toList(growable: false);

    topologies[switchName.toString()] = specs;
  });

  return topologies;
}

List<_DirectPortSpec> _parseDirectPortSpecs({
  required dynamic builtinPorts,
  required dynamic boardJson,
}) {
  final specsByDevice = <String, _DirectPortSpec>{};

  for (final item in _directPortItems(builtinPorts)) {
    final port = _asMap(item);
    final device = _cleanString(port['device']);
    if (device == null) continue;

    final label = _cleanString(port['label']) ?? device;
    specsByDevice[device] = _DirectPortSpec(device: device, label: label);
  }

  if (specsByDevice.isEmpty) {
    final network = _asMap(_asMap(boardJson)['network']);
    for (final role in ['lan', 'wan']) {
      final section = _asMap(network[role]);
      final ports = section['ports'];
      if (ports is List) {
        for (final port in ports) {
          final device = _cleanString(port);
          if (device != null) {
            specsByDevice[device] = _DirectPortSpec(
              device: device,
              label: device,
            );
          }
        }
      } else {
        final device = _cleanString(section['device']);
        if (device != null) {
          specsByDevice[device] = _DirectPortSpec(
            device: device,
            label: device,
          );
        }
      }
    }
  }

  final specs = specsByDevice.values.toList();
  specs.sort((a, b) => a.device.compareTo(b.device));
  return specs;
}

List<dynamic> _directPortItems(dynamic rawPorts) {
  if (rawPorts is List) return rawPorts;
  final ports = _asMap(rawPorts);
  final result = ports['result'];
  if (result is List) return result;
  return const [];
}

Map<dynamic, dynamic> _directDeviceStatus(
  String device, {
  required Map<String, dynamic> deviceStatuses,
  required dynamic networkDevices,
}) {
  final directStatus = _asMap(deviceStatuses[device]);
  if (directStatus.isNotEmpty) return directStatus;

  final deviceData = _asMap(_asMap(networkDevices)[device]);
  if (deviceData.isEmpty) return const {};

  final stats = _asMap(deviceData['stats']);
  if (stats.isNotEmpty) {
    return {
      ...deviceData,
      ...stats,
    };
  }
  return deviceData;
}

Map<int, _SwitchPortState> _parsePortStates(dynamic rawStatus) {
  final states = <int, _SwitchPortState>{};
  final items = _statusItems(rawStatus);

  for (var index = 0; index < items.length; index++) {
    final item = _asMap(items[index]);
    if (item.isEmpty) continue;

    final port = _toInt(item['port'] ?? item['num'] ?? item['id']) ?? index;
    final speed = _toInt(item['speed']);
    final parsedLink = _toBoolOrNull(item['link']);
    final link = parsedLink ?? ((speed ?? 0) > 0);

    states[port] = _SwitchPortState(
      link: link,
      speed: speed,
      duplex: _toBoolOrNull(item['duplex']),
    );
  }

  return states;
}

List<dynamic> _statusItems(dynamic rawStatus) {
  if (rawStatus is List) return rawStatus;

  final status = _asMap(rawStatus);
  for (final key in ['result', 'ports', 'portstate']) {
    final value = status[key];
    if (value is List) return value;
  }

  final items = <dynamic>[];
  status.forEach((key, value) {
    final port = _toInt(key);
    if (port == null) return;

    final item = Map<String, dynamic>.from(_asMap(value));
    item['port'] = port;
    items.add(item);
  });
  return items;
}

String? _switchTitle(dynamic rawFeatures) {
  final features = _asMap(rawFeatures);
  return _cleanString(features['switch_title'] ?? features['title']);
}

Map<dynamic, dynamic> _uciValues(dynamic uciConfig) {
  final config = _asMap(uciConfig);
  final values = config['values'];
  if (values is Map) return values;

  final network = config['network'];
  if (network is Map) return network;

  return config;
}

Map<dynamic, dynamic> _asMap(dynamic value) {
  if (value is Map) return value;
  return const {};
}

String? _cleanString(dynamic value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool? _toBoolOrNull(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'up':
      case 'link':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'down':
      case 'none':
        return false;
    }
  }
  return null;
}

bool? _toDuplexBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'full':
      case '1':
      case 'true':
      case 'yes':
        return true;
      case 'half':
      case '0':
      case 'false':
      case 'no':
        return false;
    }
  }
  return null;
}

class _RawSwitchPortSpec {
  final int number;
  final String role;
  final int index;
  final String? device;

  const _RawSwitchPortSpec({
    required this.number,
    required this.role,
    required this.index,
    this.device,
  });
}

class _SwitchPortSpec {
  final int number;
  final String role;
  final String label;
  final bool isCpu;
  final String? device;

  const _SwitchPortSpec({
    required this.number,
    required this.role,
    required this.label,
    required this.isCpu,
    this.device,
  });
}

class _DirectPortSpec {
  final String device;
  final String label;

  const _DirectPortSpec({
    required this.device,
    required this.label,
  });
}

class _SwitchPortState {
  final bool link;
  final int? speed;
  final bool? duplex;

  const _SwitchPortState({
    required this.link,
    this.speed,
    this.duplex,
  });
}
