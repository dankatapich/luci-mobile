import 'package:flutter/material.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/models/switch_port.dart';

class SwitchPortsCard extends StatelessWidget {
  final SwitchPortGroup group;

  const SwitchPortsCard({required this.group, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ports = group.visiblePorts;
    final hasConnectedPorts = group.connectedPortCount > 0;

    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: LuciCardStyles.standardRadius,
        side: BorderSide(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.10),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LuciSpacing.lg,
          vertical: LuciSpacing.md,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.settings_ethernet,
                    color: hasConnectedPorts
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                    size: 22,
                    semanticLabel: 'Network ports',
                  ),
                ),
                const SizedBox(width: LuciSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.displayName,
                        style: LuciTextStyles.cardTitle(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: LuciSpacing.xs),
                      Text(
                        group.summary,
                        style: LuciTextStyles.cardSubtitle(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                LuciStatusIndicators.statusChip(
                  context,
                  '${group.connectedPortCount}/${ports.length}',
                  hasConnectedPorts,
                ),
              ],
            ),
            const SizedBox(height: LuciSpacing.sm),
            Divider(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.14),
              thickness: 1,
              height: 1,
            ),
            const SizedBox(height: LuciSpacing.xs),
            ...ports.map((port) => _SwitchPortRow(port: port)),
          ],
        ),
      ),
    );
  }
}

class _SwitchPortRow extends StatelessWidget {
  final SwitchPort port;

  const _SwitchPortRow({required this.port});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = !port.hasStatus
        ? colorScheme.outline
        : (port.isConnected ? Colors.green : colorScheme.error);
    final icon = port.isConnected ? Icons.lan_outlined : Icons.link_off;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LuciSpacing.sm),
      child: Row(
        children: [
          Tooltip(
            message: port.statusText,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: LuciSpacing.sm),
          Icon(icon, size: 18, color: statusColor),
          const SizedBox(width: LuciSpacing.sm),
          Expanded(
            child: Text(
              port.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: LuciSpacing.sm),
          Flexible(
            child: Text(
              port.statusText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
