import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/models/nlbwmon.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_refresh_components.dart';

class NlbwmonScreen extends ConsumerStatefulWidget {
  const NlbwmonScreen({super.key});

  @override
  ConsumerState<NlbwmonScreen> createState() => _NlbwmonScreenState();
}

class _NlbwmonScreenState extends ConsumerState<NlbwmonScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = ref.read(appStateProvider);
      if (appState.nlbwmonSnapshot == null && !appState.isNlbwmonLoading) {
        unawaited(appState.fetchNlbwmonData());
      }
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final decimals = value >= 100 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unit]}';
  }

  String _formatNumber(int value) {
    if (value < 1000) return value.toString();
    if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 1000000).toStringAsFixed(1)}m';
  }

  Map<String, String> _hostNames(AppState appState) {
    final leases = appState.dashboardData?['dhcpLeases'];
    final result = <String, String>{};
    if (leases is! Map) return result;

    final leaseList = leases['dhcp_leases'];
    if (leaseList is! List) return result;

    for (final lease in leaseList) {
      if (lease is! Map) continue;
      final hostname = lease['hostname']?.toString();
      if (hostname == null || hostname.isEmpty || hostname == '*') continue;

      final mac = lease['macaddr']?.toString().toUpperCase();
      final ip = lease['ipaddr']?.toString();
      if (mac != null && mac.isNotEmpty) result[mac] = hostname;
      if (ip != null && ip.isNotEmpty) result[ip] = hostname;
    }

    return result;
  }

  String _hostTitle(NlbwmonUsageEntry entry, Map<String, String> hostNames) {
    final mac = entry.macAddress;
    if (mac != null && hostNames[mac] != null) return hostNames[mac]!;

    final ip = entry.ipAddress;
    if (ip != null && hostNames[ip] != null) return hostNames[ip]!;

    return entry.label;
  }

  String _hostSubtitle(NlbwmonUsageEntry entry) {
    final parts = <String>[
      if (entry.ipAddress != null) entry.ipAddress!,
      if (entry.macAddress != null) entry.macAddress!,
    ];
    if (parts.isEmpty) return 'Unknown host';
    return parts.join('  ');
  }

  Widget _buildSummaryCard(BuildContext context, NlbwmonSnapshot snapshot) {
    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 8.0),
        child: Row(
          children: [
            _SummaryMetric(
              label: 'Down',
              value: _formatBytes(snapshot.totalRxBytes),
              icon: Icons.arrow_downward,
              color: Colors.green,
            ),
            _SummaryMetric(
              label: 'Up',
              value: _formatBytes(snapshot.totalTxBytes),
              icon: Icons.arrow_upward,
              color: Colors.blue,
            ),
            _SummaryMetric(
              label: 'Hosts',
              value: snapshot.hostCount.toString(),
              icon: Icons.devices_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            _SummaryMetric(
              label: 'Conn.',
              value: _formatNumber(snapshot.totalConnections),
              icon: Icons.hub_outlined,
              color: Theme.of(context).colorScheme.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsageList({
    required BuildContext context,
    required String title,
    required IconData icon,
    required List<NlbwmonUsageEntry> entries,
    required String Function(NlbwmonUsageEntry entry) titleFor,
    required String Function(NlbwmonUsageEntry entry) subtitleFor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final shown = entries.take(20).toList(growable: false);

    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                child: Center(
                  child: Text(
                    'No data recorded yet',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              ...shown.map(
                (entry) => _UsageRow(
                  title: titleFor(entry),
                  subtitle: subtitleFor(entry),
                  rx: _formatBytes(entry.rxBytes),
                  tx: _formatBytes(entry.txBytes),
                  total: _formatBytes(entry.totalBytes),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppState appState) {
    final snapshot = appState.nlbwmonSnapshot;
    if (appState.isNlbwmonLoading && snapshot == null) {
      return const LuciLoadingWidget();
    }

    if (snapshot == null) {
      return LuciEmptyState(
        title: 'Bandwidth Monitor Unavailable',
        message:
            'The nlbwmon LuCI extension is not available on this router.',
        icon: Icons.query_stats_outlined,
        actionLabel: 'Retry',
        onAction: () {
          unawaited(appState.fetchNlbwmonData());
        },
      );
    }

    final hostNames = _hostNames(appState);

    return LuciPullToRefresh(
      onRefresh: () => appState.fetchNlbwmonData(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _buildSummaryCard(context, snapshot),
          const SizedBox(height: 12),
          _buildUsageList(
            context: context,
            title: 'Top Hosts',
            icon: Icons.devices_outlined,
            entries: snapshot.hosts,
            titleFor: (entry) => _hostTitle(entry, hostNames),
            subtitleFor: _hostSubtitle,
          ),
          const SizedBox(height: 12),
          _buildUsageList(
            context: context,
            title: 'Applications',
            icon: Icons.apps_outlined,
            entries: snapshot.protocols,
            titleFor: (entry) => entry.label,
            subtitleFor: (entry) => '${_formatNumber(entry.connections)} conn.',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    return Scaffold(
      appBar: const LuciAppBar(title: 'Bandwidth'),
      body: SafeArea(
        top: true,
        bottom: false,
        child: _buildBody(appState),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String rx;
  final String tx;
  final String total;

  const _UsageRow({
    required this.title,
    required this.subtitle,
    required this.rx,
    required this.tx,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9.0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                total,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'D $rx / U $tx',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
