import 'package:flutter/material.dart';
import 'package:luci_mobile/screens/dashboard_screen.dart';
import 'package:luci_mobile/screens/nlbwmon_screen.dart';
import 'package:luci_mobile/screens/clients_screen.dart';
import 'package:luci_mobile/screens/interfaces_screen.dart';
import 'package:luci_mobile/screens/more_screen.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/widgets/luci_navigation_enhancements.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum _MainTab { dashboard, bandwidth, clients, interfaces, more }

class _MainNavigationItem {
  final _MainTab tab;
  final Widget screen;
  final NavigationDestination destination;

  const _MainNavigationItem({
    required this.tab,
    required this.screen,
    required this.destination,
  });
}

class MainScreen extends ConsumerStatefulWidget {
  final int? initialTab;
  final String? interfaceToScroll;

  const MainScreen({super.key, this.initialTab, this.interfaceToScroll});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  _MainTab _selectedTab = _MainTab.dashboard;
  String? _currentInterfaceToScroll;

  @override
  void initState() {
    super.initState();
    if (widget.initialTab != null) {
      _selectedTab = _legacyTabForIndex(widget.initialTab!);
    }
    _currentInterfaceToScroll = widget.interfaceToScroll;
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle parameter changes (important for iOS navigation)
    if (widget.interfaceToScroll != oldWidget.interfaceToScroll) {
      _currentInterfaceToScroll = widget.interfaceToScroll;
    }

    // Handle initial tab changes
    if (widget.initialTab != oldWidget.initialTab &&
        widget.initialTab != null) {
      _selectedTab = _legacyTabForIndex(widget.initialTab!);
    }
  }

  void _clearInterfaceToScroll() {
    if (_currentInterfaceToScroll != null) {
      setState(() {
        _currentInterfaceToScroll = null;
      });
    }
  }

  _MainTab _legacyTabForIndex(int index) {
    switch (index) {
      case 1:
        return _MainTab.clients;
      case 2:
        return _MainTab.interfaces;
      case 3:
        return _MainTab.more;
      case 0:
      default:
        return _MainTab.dashboard;
    }
  }

  void _onItemTapped(_MainTab tab) {
    setState(() {
      _selectedTab = tab;
    });

    // Clear interface scroll state when navigating away from Interfaces tab
    if (_selectedTab != _MainTab.interfaces &&
        _currentInterfaceToScroll != null) {
      _clearInterfaceToScroll();
    }
  }

  List<_MainNavigationItem> _navigationItems({
    required bool showBandwidth,
    required bool isRebooting,
  }) {
    Color? getTabColor(_MainTab tab) => (isRebooting && tab != _MainTab.more)
        ? Colors.grey.withAlpha(128)
        : null;
    double getTabOpacity(_MainTab tab) =>
        (isRebooting && tab != _MainTab.more) ? 0.5 : 1.0;

    return [
      _MainNavigationItem(
        tab: _MainTab.dashboard,
        screen: const DashboardScreen(),
        destination: NavigationDestination(
          selectedIcon: Opacity(
            opacity: getTabOpacity(_MainTab.dashboard),
            child: Icon(Icons.dashboard, color: getTabColor(_MainTab.dashboard)),
          ),
          icon: Opacity(
            opacity: getTabOpacity(_MainTab.dashboard),
            child: Icon(
              Icons.dashboard_outlined,
              color: getTabColor(_MainTab.dashboard),
            ),
          ),
          label: 'Dashboard',
        ),
      ),
      if (showBandwidth)
        _MainNavigationItem(
          tab: _MainTab.bandwidth,
          screen: const NlbwmonScreen(),
          destination: NavigationDestination(
            selectedIcon: Opacity(
              opacity: getTabOpacity(_MainTab.bandwidth),
              child: Icon(
                Icons.query_stats,
                color: getTabColor(_MainTab.bandwidth),
              ),
            ),
            icon: Opacity(
              opacity: getTabOpacity(_MainTab.bandwidth),
              child: Icon(
                Icons.query_stats_outlined,
                color: getTabColor(_MainTab.bandwidth),
              ),
            ),
            label: 'Bandwidth',
          ),
        ),
      _MainNavigationItem(
        tab: _MainTab.clients,
        screen: const ClientsScreen(),
        destination: NavigationDestination(
          selectedIcon: Opacity(
            opacity: getTabOpacity(_MainTab.clients),
            child: Icon(Icons.people, color: getTabColor(_MainTab.clients)),
          ),
          icon: Opacity(
            opacity: getTabOpacity(_MainTab.clients),
            child: Icon(
              Icons.people_outline,
              color: getTabColor(_MainTab.clients),
            ),
          ),
          label: 'Clients',
        ),
      ),
      _MainNavigationItem(
        tab: _MainTab.interfaces,
        screen: InterfacesScreen(
          scrollToInterface: _currentInterfaceToScroll,
          onScrollComplete: _clearInterfaceToScroll,
        ),
        destination: NavigationDestination(
          selectedIcon: Opacity(
            opacity: getTabOpacity(_MainTab.interfaces),
            child: Icon(Icons.lan, color: getTabColor(_MainTab.interfaces)),
          ),
          icon: Opacity(
            opacity: getTabOpacity(_MainTab.interfaces),
            child: Icon(
              Icons.lan_outlined,
              color: getTabColor(_MainTab.interfaces),
            ),
          ),
          label: 'Interfaces',
        ),
      ),
      _MainNavigationItem(
        tab: _MainTab.more,
        screen: const MoreScreen(),
        destination: NavigationDestination(
          selectedIcon: Opacity(
            opacity: getTabOpacity(_MainTab.more),
            child: const Icon(Icons.more_horiz),
          ),
          icon: Opacity(
            opacity: getTabOpacity(_MainTab.more),
            child: const Icon(Icons.more_horiz_outlined),
          ),
          label: 'More',
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Listen for requestedTab in AppState
    final appState = ref.watch(appStateProvider);
    final showBandwidth = appState.isNlbwmonAvailable;
    final isRebooting = ref.watch(
      appStateProvider.select((state) => state.isRebooting),
    );
    final items = _navigationItems(
      showBandwidth: showBandwidth,
      isRebooting: isRebooting,
    );
    final effectiveSelectedTab = items.any((item) => item.tab == _selectedTab)
        ? _selectedTab
        : _MainTab.dashboard;
    final selectedIndex =
        items.indexWhere((item) => item.tab == effectiveSelectedTab);
    final selectedItem = items[selectedIndex < 0 ? 0 : selectedIndex];

    if (appState.requestedTab != null) {
      // Store the values before the callback to avoid null reference issues
      final requestedTab = _legacyTabForIndex(appState.requestedTab!);
      final requestedInterface = appState.requestedInterfaceToScroll;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedTab = requestedTab;
          // Update interface to scroll if provided
          if (requestedInterface != null) {
            _currentInterfaceToScroll = requestedInterface;
          }
        });
        appState.requestedTab = null;
        appState.requestedInterfaceToScroll = null;
      });
    }
    return Scaffold(
      body: Center(
        child: LuciTabTransition(
          transitionKey: 'tab_${selectedItem.tab.name}',
          child: selectedItem.screen,
        ),
      ),
      bottomNavigationBar: Builder(
        builder: (context) {
          return NavigationBar(
            onDestinationSelected: (index) {
              final tab = items[index].tab;
              if (isRebooting && tab != _MainTab.more) return;
              _onItemTapped(tab);
            },
            selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
            destinations: items.map((item) => item.destination).toList(),
          );
        },
      ),
    );
  }
}
