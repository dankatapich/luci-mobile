class NlbwmonSnapshot {
  final List<String> periods;
  final String? selectedPeriod;
  final List<NlbwmonUsageEntry> hosts;
  final List<NlbwmonUsageEntry> protocols;

  const NlbwmonSnapshot({
    required this.periods,
    required this.hosts,
    required this.protocols,
    this.selectedPeriod,
  });

  int get totalRxBytes => hosts.fold(0, (sum, entry) => sum + entry.rxBytes);
  int get totalTxBytes => hosts.fold(0, (sum, entry) => sum + entry.txBytes);
  int get totalBytes => totalRxBytes + totalTxBytes;
  int get totalConnections =>
      hosts.fold(0, (sum, entry) => sum + entry.connections);
  int get hostCount => hosts.length;

  factory NlbwmonSnapshot.fromActionData(
    Map<String, dynamic> data, {
    List<String> periods = const [],
    String? selectedPeriod,
  }) {
    final columnsRaw = data['columns'];
    final rowsRaw = data['data'];
    if (columnsRaw is! List || rowsRaw is! List) {
      throw const FormatException('Malformed nlbwmon data');
    }

    final columns = <String, int>{};
    for (var i = 0; i < columnsRaw.length; i++) {
      columns[columnsRaw[i].toString()] = i;
    }

    final hosts = <String, NlbwmonUsageEntry>{};
    final protocols = <String, NlbwmonUsageEntry>{};

    for (final rowRaw in rowsRaw) {
      if (rowRaw is! List) continue;
      final record = _NlbwmonRecord(columns, rowRaw);
      if (record.rxBytes <= 0 && record.txBytes <= 0) continue;

      final hostKey = record.hostKey;
      hosts[hostKey] = (hosts[hostKey] ?? NlbwmonUsageEntry.host(record))
          .merge(record);

      final protocolKey = record.protocolKey;
      protocols[protocolKey] =
          (protocols[protocolKey] ?? NlbwmonUsageEntry.protocol(record)).merge(
        record,
      );
    }

    final hostEntries = hosts.values.toList()
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    final protocolEntries = protocols.values.toList()
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));

    return NlbwmonSnapshot(
      periods: periods,
      selectedPeriod: selectedPeriod,
      hosts: hostEntries,
      protocols: protocolEntries,
    );
  }
}

class NlbwmonUsageEntry {
  final String key;
  final String label;
  final String? macAddress;
  final String? ipAddress;
  final String? protocol;
  final int connections;
  final int rxBytes;
  final int txBytes;
  final int rxPackets;
  final int txPackets;

  const NlbwmonUsageEntry({
    required this.key,
    required this.label,
    required this.connections,
    required this.rxBytes,
    required this.txBytes,
    required this.rxPackets,
    required this.txPackets,
    this.macAddress,
    this.ipAddress,
    this.protocol,
  });

  factory NlbwmonUsageEntry.host(_NlbwmonRecord record) {
    return NlbwmonUsageEntry(
      key: record.hostKey,
      label: record.hostLabel,
      macAddress: record.normalizedMac,
      ipAddress: record.ipAddress,
      connections: 0,
      rxBytes: 0,
      txBytes: 0,
      rxPackets: 0,
      txPackets: 0,
    );
  }

  factory NlbwmonUsageEntry.protocol(_NlbwmonRecord record) {
    return NlbwmonUsageEntry(
      key: record.protocolKey,
      label: record.protocolLabel,
      protocol: record.protocolLabel,
      connections: 0,
      rxBytes: 0,
      txBytes: 0,
      rxPackets: 0,
      txPackets: 0,
    );
  }

  int get totalBytes => rxBytes + txBytes;

  NlbwmonUsageEntry merge(_NlbwmonRecord record) {
    return NlbwmonUsageEntry(
      key: key,
      label: label,
      macAddress: macAddress ?? record.normalizedMac,
      ipAddress: ipAddress ?? record.ipAddress,
      protocol: protocol,
      connections: connections + record.connections,
      rxBytes: rxBytes + record.rxBytes,
      txBytes: txBytes + record.txBytes,
      rxPackets: rxPackets + record.rxPackets,
      txPackets: txPackets + record.txPackets,
    );
  }
}

class _NlbwmonRecord {
  final Map<String, int> columns;
  final List<dynamic> row;

  const _NlbwmonRecord(this.columns, this.row);

  String? get normalizedMac {
    final mac = _stringValue('mac')?.toUpperCase();
    if (mac == null || mac == '00:00:00:00:00:00') return null;
    return mac;
  }

  String? get ipAddress => _stringValue('ip');

  String get hostKey => normalizedMac ?? ipAddress ?? 'other';

  String get hostLabel => normalizedMac ?? ipAddress ?? 'Other';

  String get protocolLabel {
    final layer7 = _stringValue('layer7');
    if (layer7 == null || layer7.isEmpty) return 'Other';
    return layer7;
  }

  String get protocolKey => protocolLabel.toLowerCase();

  int get connections => _intValue('conns');
  int get rxBytes => _intValue('rx_bytes');
  int get txBytes => _intValue('tx_bytes');
  int get rxPackets => _intValue('rx_pkts');
  int get txPackets => _intValue('tx_pkts');

  String? _stringValue(String column) {
    final index = columns[column];
    if (index == null || index < 0 || index >= row.length) return null;
    final value = row[index];
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  int _intValue(String column) {
    final index = columns[column];
    if (index == null || index < 0 || index >= row.length) return 0;
    final value = row[index];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
