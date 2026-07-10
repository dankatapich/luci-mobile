import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/models/client.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';
import 'package:luci_mobile/widgets/luci_refresh_components.dart';
import 'package:luci_mobile/widgets/luci_animation_system.dart';

class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen>
    with SingleTickerProviderStateMixin {
  String _searchQuery = '';
  final Set<int> _expandedClientIndices = {};
  late AnimationController _controller;
  late TextEditingController _searchController;
  ClientsViewMode _clientsViewMode = ClientsViewMode.all;
  Future<List<Client>>? _clientsFuture;
  String? _lastSelectedRouterId;
  String _lastNlbwmonSignature = '';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _searchController = TextEditingController();
    _searchController.addListener(() {
      if (_searchQuery != _searchController.text) {
        setState(() {
          _searchQuery = _searchController.text;
        });
      }
    });
    // Initialize toggle from persisted state
    final initState = ref.read(appStateProvider);
    _clientsViewMode = initState.clientsViewMode;
    _lastSelectedRouterId = initState.selectedRouter?.id;
    _lastNlbwmonSignature = _nlbwmonClientSignature(initState);
    _computeClientsFuture();
  }

  String _nlbwmonClientSignature(AppState appState) {
    final snapshot = appState.nlbwmonSnapshot;
    if (snapshot == null) return 'unavailable';
    return snapshot.hosts
        .map(
          (host) =>
              '${host.macAddress ?? ''}|${host.ipAddress ?? ''}',
        )
        .join(';');
  }

  void _computeClientsFuture() {
    final appState = ref.read(appStateProvider);
    switch (_clientsViewMode) {
      case ClientsViewMode.all:
        _clientsFuture = appState.fetchAggregatedClients();
        break;
      case ClientsViewMode.selected:
        _clientsFuture = appState.fetchClientsForSelectedRouter();
        break;
      case ClientsViewMode.blocked:
        _clientsFuture = appState.fetchBlockedClients();
        break;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final watchedAppState = ref.watch(appStateProvider);
    // Recompute future when the selected router or saved client view changes.
    Future<List<Client>>? future = _clientsFuture;
    if (watchedAppState.clientsViewMode != _clientsViewMode) {
      _clientsViewMode = watchedAppState.clientsViewMode;
      _expandedClientIndices.clear();
      _computeClientsFuture();
      future = _clientsFuture;
    }
    final currentId = watchedAppState.selectedRouter?.id;
    if (currentId != _lastSelectedRouterId) {
      _lastSelectedRouterId = currentId;
      _computeClientsFuture();
      future = _clientsFuture;
    }
    final nlbwmonSignature = _nlbwmonClientSignature(watchedAppState);
    if (nlbwmonSignature != _lastNlbwmonSignature) {
      _lastNlbwmonSignature = nlbwmonSignature;
      _computeClientsFuture();
      future = _clientsFuture;
    }
    return FutureBuilder<List<Client>>(
      key: ValueKey('${_clientsViewMode.name}:${currentId ?? ''}'),
      future: future,
      builder: (context, snapshot) {
        final aggregatedClients = snapshot.data ?? [];
        return Scaffold(
          appBar: const LuciAppBar(title: 'Clients'),
          body: Stack(
            children: [
              LuciPullToRefresh(
                onRefresh: () async {
                  // Trigger a refresh by re-fetching dashboard data for selected router
                  await ref.read(appStateProvider).fetchDashboardData();
                  setState(() {
                    _computeClientsFuture();
                  });
                },
                child: Builder(
                  builder: (context) {
                    final appState = ref.watch(appStateProvider);
                    final isLoading = snapshot.connectionState == ConnectionState.waiting && (aggregatedClients.isEmpty);
                    final dashboardError = appState.dashboardError;

                    if (isLoading) {
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: LuciSpacing.md,
                        ),
                        child: Column(
                          children: [
                            SizedBox(height: LuciSpacing.md),
                            // Search bar skeleton
                            LuciSkeleton(
                              width: double.infinity,
                              height: 56,
                              borderRadius: BorderRadius.circular(
                                LuciSpacing.sm,
                              ),
                            ),
                            SizedBox(height: LuciSpacing.md),
                            // Client list skeletons
                            Expanded(
                              child: ListView.separated(
                                itemCount: 6,
                                separatorBuilder: (context, index) =>
                                    SizedBox(height: LuciSpacing.sm),
                                itemBuilder: (context, index) =>
                                    LuciListItemSkeleton(
                                      showLeading: true,
                                      showTrailing: true,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    if (dashboardError != null && aggregatedClients.isEmpty) {
                      return LuciErrorDisplay(
                        title: 'Failed to Load Clients',
                        message:
                            'Could not connect to the router. Please check your network connection and the router\'s IP address.',
                        actionLabel: 'Retry',
                        onAction: () =>
                            ref.read(appStateProvider).fetchDashboardData(),
                        icon: Icons.wifi_off_rounded,
                      );
                    }

                    final clients = aggregatedClients;

                    final filteredClients = clients.where((client) {
                      final query = _searchQuery.toLowerCase();
                      return client.hostname.toLowerCase().contains(query) ||
                          client.ipAddress.toLowerCase().contains(query) ||
                          client.macAddress.toLowerCase().contains(query) ||
                          (client.vendor != null &&
                              client.vendor!.toLowerCase().contains(query)) ||
                          (client.dnsName != null &&
                              client.dnsName!.toLowerCase().contains(query));
                    }).toList();

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 8.0,
                          ),
                          child: TextField(
                            autofocus: false,
                            onChanged: (value) {
                              // No need to setState here, listener handles it
                            },
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: 'Search by name, IP, MAC, vendor...',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear),
                                      onPressed: () {
                                        setState(() {
                                          _searchController.clear();
                                        });
                                      },
                                      tooltip: 'Clear search',
                                    )
                                  : null,
                              filled: true,
                              fillColor: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.8),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24.0),
                                borderSide: BorderSide.none,
                              ),
                              hintStyle: TextStyle(
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 4.0,
                          ),
                          child: SegmentedButton<ClientsViewMode>(
                            segments: const [
                              ButtonSegment<ClientsViewMode>(
                                value: ClientsViewMode.all,
                                label: Text('All'),
                                icon: Icon(Icons.apartment),
                              ),
                              ButtonSegment<ClientsViewMode>(
                                value: ClientsViewMode.selected,
                                label: Text('Selected'),
                                icon: Icon(Icons.router),
                              ),
                              ButtonSegment<ClientsViewMode>(
                                value: ClientsViewMode.blocked,
                                label: Text('Blocked'),
                                icon: Icon(Icons.block),
                              ),
                            ],
                            selected: {_clientsViewMode},
                            showSelectedIcon: false,
                            style: SegmentedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onSelectionChanged: (s) {
                              final selectedMode = s.first;
                              setState(() {
                                _clientsViewMode = selectedMode;
                                _expandedClientIndices.clear();
                                _computeClientsFuture();
                              });
                              // Persist selection
                              unawaited(
                                ref
                                    .read(appStateProvider)
                                    .setClientsViewMode(selectedMode),
                              );
                            },
                          ),
                        ),
                        Expanded(
                          child: filteredClients.isEmpty
                              ? LuciEmptyState(
                                  title: _searchQuery.isEmpty
                                      ? _clientsViewMode ==
                                              ClientsViewMode.blocked
                                          ? 'No Blocked Clients'
                                          : 'No Active Clients Found'
                                      : 'No Matching Clients',
                                  message: _searchQuery.isEmpty
                                      ? _clientsViewMode ==
                                              ClientsViewMode.blocked
                                          ? 'No app-created client block rules were found.'
                                          : 'No clients are currently connected to the router. Pull down to refresh the list.'
                                      : 'No clients match your search criteria. Try a different search term.',
                                  icon: _clientsViewMode ==
                                          ClientsViewMode.blocked
                                      ? Icons.block
                                      : Icons.people_outline,
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  separatorBuilder: (context, idx) =>
                                      const SizedBox(height: 4),
                                  itemCount: filteredClients.length,
                                  itemBuilder: (context, index) {
                                    final client = filteredClients[index];
                                    final isExpanded = _expandedClientIndices
                                        .contains(index);

                                    return LuciSlideTransition(
                                      direction: LuciSlideDirection.up,
                                      delay: Duration(milliseconds: index * 50),
                                      distance: 30,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16.0,
                                          vertical: 8.0,
                                        ),
                                        child: _UnifiedClientCard(
                                          client: client,
                                          isExpanded: isExpanded,
                                          onToggleBlocked: (client) async {
                                            final appState = ref.read(
                                              appStateProvider,
                                            );
                                            final success = client.isBlocked
                                                ? await appState.unblockClient(
                                                    client,
                                                    context: context,
                                                  )
                                                : await appState.blockClient(
                                                    client,
                                                    context: context,
                                                  );
                                            if (!context.mounted) {
                                              return success;
                                            }
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  success
                                                      ? client.isBlocked
                                                          ? 'Client unblocked'
                                                          : 'Client blocked'
                                                      : client.isBlocked
                                                          ? 'Failed to unblock client'
                                                          : 'Failed to block client',
                                                ),
                                                duration: const Duration(
                                                  seconds: 2,
                                                ),
                                              ),
                                            );
                                            if (success && mounted) {
                                              setState(() {
                                                _computeClientsFuture();
                                              });
                                            }
                                            return success;
                                          },
                                          onTap: () {
                                            setState(() {
                                              if (isExpanded) {
                                                _expandedClientIndices.remove(
                                                  index,
                                                );
                                              } else {
                                                _expandedClientIndices.add(
                                                  index,
                                                );
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String normalizeMac(String mac) => mac.toUpperCase().replaceAll('-', ':');
}

class _UnifiedClientCard extends StatefulWidget {
  final Client client;
  final bool isExpanded;
  final VoidCallback onTap;
  final Future<bool> Function(Client client) onToggleBlocked;

  const _UnifiedClientCard({
    required this.client,
    required this.isExpanded,
    required this.onTap,
    required this.onToggleBlocked,
  });

  @override
  State<_UnifiedClientCard> createState() => _UnifiedClientCardState();
}

class _UnifiedClientCardState extends State<_UnifiedClientCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isTogglingBlocked = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    if (widget.isExpanded) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_UnifiedClientCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      if (widget.isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: widget.isExpanded ? 6 : 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18.0),
        side: BorderSide(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.10),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedScale(
        scale: widget.isExpanded ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutBack,
        child: Column(
          children: [
            InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(18.0),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Row(
                  children: [
                    Stack(
                      alignment: Alignment.topRight,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8.0),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer.withValues(
                              alpha: 0.13,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: AnimatedScale(
                            scale: widget.isExpanded ? 1.1 : 1.0,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.elasticOut,
                            child: Icon(
                              Icons.person_outline,
                              color: colorScheme.primary,
                              size: 22,
                              semanticLabel: 'Client icon',
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Tooltip(
                            message: widget.client.isBlocked
                                ? 'Client is blocked'
                                : widget.client.connectionType ==
                                        ConnectionType.unknown
                                    ? 'Unknown connection type'
                                    : 'Client is online',
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: widget.client.isBlocked
                                    ? theme.colorScheme.error
                                    : widget.client.connectionType ==
                                                ConnectionType.wireless ||
                                            widget.client.connectionType ==
                                                ConnectionType.wired
                                        ? Colors.green
                                        : Colors.amber,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colorScheme.surface,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.client.hostname,
                            style: LuciTextStyles.cardTitle(context),
                            semanticsLabel:
                                'Client hostname: ${widget.client.hostname}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: LuciSpacing.xs),
                          Container(
                            margin: const EdgeInsets.only(right: 32),
                            child: Divider(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.10),
                              thickness: 1,
                              height: 8,
                            ),
                          ),
                          Text(
                            _buildMinimalClientSubtitle(widget.client),
                            style: LuciTextStyles.cardSubtitle(context),
                            semanticsLabel:
                                'Client details: ${_buildMinimalClientSubtitle(widget.client)}',
                          ),
                          if (widget.client.vendor != null &&
                              widget.client.vendor!.isNotEmpty)
                            Text(
                              widget.client.vendor!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              semanticsLabel: 'Vendor: ${widget.client.vendor}',
                            ),
                        ],
                      ),
                    ),
                    _buildConnectionTypeChip(
                      context,
                      widget.client.connectionType,
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      widget.isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                      size: 26,
                      semanticLabel: widget.isExpanded
                          ? 'Collapse details'
                          : 'Expand details',
                    ),
                  ],
                ),
              ),
            ),
            if (widget.isExpanded)
              Column(
                children: [
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _buildClientDetails(context, widget.client),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionTypeChip(BuildContext context, ConnectionType type) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    String label;
    IconData icon;
    Color bgColor;
    Color fgColor;

    switch (type) {
      case ConnectionType.wireless:
        label = 'Wi-Fi';
        icon = Icons.wifi;
        bgColor = colorScheme.primaryContainer;
        fgColor = colorScheme.onPrimaryContainer;
        break;
      case ConnectionType.wired:
        label = 'Wired';
        icon = Icons.settings_ethernet;
        bgColor = colorScheme.secondaryContainer;
        fgColor = colorScheme.onSecondaryContainer;
        break;
      default:
        label = 'Unknown';
        icon = Icons.devices_other_outlined;
        bgColor = colorScheme.surfaceContainerHighest;
        fgColor = colorScheme.onSurfaceVariant;
        break;
    }

    return Chip(
      label: Text(label),
      avatar: Icon(icon, size: 16, color: fgColor),
      backgroundColor: bgColor,
      labelStyle: theme.textTheme.labelSmall?.copyWith(color: fgColor),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildClientDetails(BuildContext context, Client client) {
    final theme = Theme.of(context);

    Widget detailRow(
      String title,
      String value, {
      Color? valueColor,
      VoidCallback? onTap,
      String? semanticsLabel,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LuciSpacing.md,
            vertical: LuciSpacing.sm,
          ),
          child: Row(
            children: [
              Flexible(
                flex: 4,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LuciTextStyles.detailLabel(context),
                  semanticsLabel: title,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: valueColor != null
                            ? LuciTextStyles.detailValue(
                                context,
                              ).copyWith(color: valueColor)
                            : LuciTextStyles.detailValue(context),
                        semanticsLabel: semanticsLabel ?? value,
                      ),
                    ),
                    if (onTap != null)
                      GestureDetector(
                        onTap: onTap,
                        child: const Padding(
                          padding: EdgeInsets.only(left: 8.0),
                          child: Icon(
                            Icons.copy_all_outlined,
                            size: 16,
                            semanticLabel: 'Copy',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.18,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
      ),
      child: Column(
        children: [
          detailRow(
            'IP Address',
            client.ipAddress,
            onTap: () =>
                _copyToClipboard(context, client.ipAddress, 'IP Address'),
            semanticsLabel: 'IP Address: ${client.ipAddress}',
          ),
          if (client.ipv6Addresses != null && client.ipv6Addresses!.isNotEmpty)
            ...client.ipv6Addresses!.map(
              (ipv6) => detailRow(
                'IPv6 Address',
                ipv6,
                onTap: () => _copyToClipboard(context, ipv6, 'IPv6 Address'),
                semanticsLabel: 'IPv6 Address: $ipv6',
              ),
            ),
          detailRow(
            'MAC Address',
            client.macAddress,
            onTap: () =>
                _copyToClipboard(context, client.macAddress, 'MAC Address'),
            semanticsLabel: 'MAC Address: ${client.macAddress}',
          ),
          if (client.vendor != null && client.vendor!.isNotEmpty)
            detailRow(
              'Vendor',
              client.vendor!,
              semanticsLabel: 'Vendor: ${client.vendor}',
            ),
          if (client.dnsName != null && client.dnsName!.isNotEmpty)
            detailRow(
              'DNS Name',
              client.dnsName!,
              semanticsLabel: 'DNS Name: ${client.dnsName}',
            ),
          if (client.routerName != null && client.routerName!.isNotEmpty)
            detailRow(
              'Router',
              client.routerName!,
              semanticsLabel: 'Router: ${client.routerName}',
            ),
          if (client.connectionType == ConnectionType.wireless &&
              client.hasWirelessMetrics) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            detailRow(
              'Signal-to-Noise Ratio',
              client.formattedSignalToNoiseRatio,
              semanticsLabel:
                  'Signal-to-Noise Ratio: ${client.formattedSignalToNoiseRatio}',
            ),
            detailRow(
              'Current Link Speed',
              client.formattedLinkSpeed,
              semanticsLabel: 'Current Link Speed: ${client.formattedLinkSpeed}',
            ),
          ],
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 8),
          detailRow(
            'Lease Time Remaining',
            client.formattedLeaseTime,
            valueColor: client.formattedLeaseTime == 'Expired'
                ? theme.colorScheme.error
                : null,
            semanticsLabel:
                'Lease Time Remaining: ${client.formattedLeaseTime}',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuciSpacing.md,
              LuciSpacing.sm,
              LuciSpacing.md,
              LuciSpacing.sm,
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isTogglingBlocked || client.macAddress == 'N/A'
                    ? null
                    : () async {
                        setState(() {
                          _isTogglingBlocked = true;
                        });
                        await widget.onToggleBlocked(client);
                        if (!mounted) return;
                        setState(() {
                          _isTogglingBlocked = false;
                        });
                      },
                icon: _isTogglingBlocked
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : Icon(
                        client.isBlocked
                            ? Icons.lock_open_outlined
                            : Icons.block,
                      ),
                label: Text(
                  _isTogglingBlocked
                      ? client.isBlocked
                          ? 'Unblocking...'
                          : 'Blocking...'
                      : client.isBlocked
                          ? 'Unblock Client'
                          : 'Block Client',
                ),
                style: client.isBlocked
                    ? null
                    : FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _buildMinimalClientSubtitle(Client client) {
    final v4 = client.ipAddress;
    final v6s = client.ipv6Addresses ?? [];
    final v6 = v6s.isNotEmpty ? v6s.first : null;
    String? shown;
    int extra = 0;
    if (v4 != 'N/A') {
      shown = v4;
      if (v6 != null) extra++;
    } else if (v6 != null) {
      shown = v6;
    }
    if (shown == null) return '';
    if (extra > 0) {
      return '$shown  +$extra';
    } else {
      return shown;
    }
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
