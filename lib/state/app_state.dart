import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:luci_mobile/services/secure_storage_service.dart';
import 'package:luci_mobile/services/router_service.dart';
import 'package:luci_mobile/services/throughput_service.dart';
import 'package:luci_mobile/models/client.dart';
import 'package:luci_mobile/models/router.dart' as model;
import 'package:luci_mobile/models/dashboard_preferences.dart';
import 'package:luci_mobile/models/nlbwmon.dart';
import 'package:luci_mobile/models/switch_port.dart';
import 'package:luci_mobile/services/interfaces/auth_service_interface.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/api_service.dart';
import 'package:luci_mobile/services/service_factory.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/utils/http_client_manager.dart';
import 'package:luci_mobile/utils/logger.dart';

enum ClientsViewMode { all, selected, blocked }

class _RouterSession {
  final String sysauth;
  final bool useHttps;

  _RouterSession({
    required this.sysauth,
    required this.useHttps,
  });
}

class _BlockedClientRule {
  final String macAddress;
  final String section;
  final String ipAddress;
  final String hostname;
  final model.Router? router;

  _BlockedClientRule({
    required this.macAddress,
    required this.section,
    required this.ipAddress,
    required this.hostname,
    this.router,
  });
}

class _NlbwmonClientHost {
  final NlbwmonUsageEntry usage;
  final model.Router? router;

  _NlbwmonClientHost({
    required this.usage,
    this.router,
  });
}

class AppState extends ChangeNotifier {
  static AppState? _instance;

  late final SecureStorageService _secureStorageService;
  IApiService? _apiService;
  IAuthService? _authService;
  RouterService? _routerService;
  ThroughputService? _throughputService;
  final HttpClientManager _httpClientManager = HttpClientManager();

  // Reviewer mode state
  bool _reviewerModeEnabled = false;
  bool get reviewerModeEnabled => _reviewerModeEnabled;

  bool _isLoading = false;
  String? _errorMessage;

  Map<String, dynamic>? _dashboardData;
  bool _isDashboardLoading = false;
  String? _dashboardError;
  NlbwmonSnapshot? _nlbwmonSnapshot;
  bool _isNlbwmonAvailable = false;
  bool _isNlbwmonLoading = false;
  String? _nlbwmonError;

  Timer? _throughputTimer;
  Timer? _pollingTimer;
  int _pollAttempts = 0;
  static const int _maxPollAttempts =
      40; // Max 40 attempts = ~5 minutes with backoff

  // Add rebooting state
  bool _isRebooting = false;
  bool get isRebooting => _isRebooting;

  // Theme mode state
  ThemeMode _themeMode = ThemeMode.system;
  static const String _themeModeKey = 'themeMode';

  // Clients view mode (aggregate across routers)
  ClientsViewMode _clientsViewMode = ClientsViewMode.all;
  static const String _clientsAggregateKey = 'clients_aggregate_all';
  static const String _blockedRuleNamePrefix = 'luci-app-';
  static const String _blockedRuleSectionPrefix = 'luci_app_block_';
  static const String _blockedRuleHostnameOption = 'luci_mobile_hostname';
  static const String _blockedRuleIpOption = 'luci_mobile_ipaddr';
  final Set<String> _mockBlockedClientMacs = {};
  ClientsViewMode get clientsViewMode => _clientsViewMode;
  bool get clientsAggregateAllRouters =>
      _clientsViewMode == ClientsViewMode.all;

  // Dashboard preferences state
  DashboardPreferences _dashboardPreferences = DashboardPreferences();
  DashboardPreferences get dashboardPreferences => _dashboardPreferences;

  List<model.Router> get routers => _routerService?.routers ?? [];
  model.Router? get selectedRouter => _routerService?.selectedRouter;

  VoidCallback? onRouterBackOnline;

  // Add requestedTab for programmatic tab switching
  int? requestedTab;
  String? requestedInterfaceToScroll;

  void requestTab(int index, {String? interfaceToScroll}) {
    requestedTab = index;
    requestedInterfaceToScroll = interfaceToScroll;
    notifyListeners();
  }

  AppState._() {
    _initialize();
  }

  static AppState get instance {
    return _instance ??= AppState._();
  }

  Future<void> _initialize() async {
    await _loadReviewerMode();
    _initializeServices();
    await _loadThemeMode();
    await loadRouters(); // Load routers on app start (sets selectedRouter)
    await _migrateGlobalDashboardPreferencesIfNeeded(); // Proactively migrate legacy prefs
    await _loadClientsViewMode();
    await loadDashboardPreferences(); // Load prefs scoped to selected router
  }

  /// One-time migration: if a global 'dashboard_preferences' exists,
  /// copy it to each router-specific key that doesn't already have prefs.
  Future<void> _migrateGlobalDashboardPreferencesIfNeeded() async {
    try {
      final globalKey = 'dashboard_preferences';
      final globalJson = await _secureStorageService.readValue(globalKey);
      if (globalJson == null || globalJson.isEmpty) return;

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return;

      // Validate JSON format before writing
      try {
        jsonDecode(globalJson);
      } catch (_) {
        return; // Not valid JSON; skip migration
      }

      for (final router in routers) {
        final key = 'dashboard_preferences:${router.id}';
        final existing = await _secureStorageService.readValue(key);
        if (existing == null || existing.isEmpty) {
          await _secureStorageService.writeValue(key, globalJson);
        }
      }

      // If all routers now have scoped prefs, remove the legacy global key
      var allHavePrefs = true;
      for (final router in routers) {
        final key = 'dashboard_preferences:${router.id}';
        final v = await _secureStorageService.readValue(key);
        if (v == null || v.isEmpty) {
          allHavePrefs = false;
          break;
        }
      }
      if (allHavePrefs) {
        await _secureStorageService.deleteValue(globalKey);
      }
    } catch (e, stack) {
      Logger.exception('Failed migrating global dashboard preferences', e, stack);
    }
  }

  Future<void> _loadReviewerMode() async {
    // Initialize secure storage service with default factory first
    ServiceContainer.configure(reviewerMode: false);
    _secureStorageService = ServiceContainer.instance.factory
        .createSecureStorageService();

    final stored = await _secureStorageService.readValue(
      AppConfig.reviewerModeKey,
    );
    _reviewerModeEnabled = stored == 'true';
  }

  void _initializeServices() {
    // Configure the service container based on reviewer mode
    ServiceContainer.configure(reviewerMode: _reviewerModeEnabled);

    // Create services using the factory
    final factory = ServiceContainer.instance.factory;
    _authService = factory.createAuthService();
    _apiService = factory.createApiService();
    _routerService = factory.createRouterService();
    _throughputService = factory.createThroughputService();
  }

  Future<void> setReviewerMode(bool enabled) async {
    _reviewerModeEnabled = enabled;
    await _secureStorageService.writeValue(
      AppConfig.reviewerModeKey,
      enabled.toString(),
    );
    _initializeServices();
    notifyListeners();
  }

  Future<void> _loadThemeMode() async {
    final stored = await _secureStorageService.readValue(_themeModeKey);
    if (stored == 'dark') {
      _themeMode = ThemeMode.dark;
    } else if (stored == 'light') {
      _themeMode = ThemeMode.light;
    } else if (stored == 'system') {
      _themeMode = ThemeMode.system;
    }
    notifyListeners();
  }

  ThemeMode get themeMode => _themeMode;
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _secureStorageService.writeValue(_themeModeKey, mode.name);
    notifyListeners();
  }

  Future<void> _loadClientsViewMode() async {
    final stored = await _secureStorageService.readValue(_clientsAggregateKey);
    if (stored == ClientsViewMode.blocked.name) {
      _clientsViewMode = ClientsViewMode.blocked;
    } else if (stored == ClientsViewMode.selected.name || stored == 'false') {
      _clientsViewMode = ClientsViewMode.selected;
    } else {
      _clientsViewMode = ClientsViewMode.all;
    }
  }

  Future<void> setClientsViewMode(ClientsViewMode mode) async {
    _clientsViewMode = mode;
    await _secureStorageService.writeValue(_clientsAggregateKey, mode.name);
    notifyListeners();
  }

  Future<void> setClientsAggregateAllRouters(bool aggregate) async {
    await setClientsViewMode(
      aggregate ? ClientsViewMode.all : ClientsViewMode.selected,
    );
  }

  Future<void> loadDashboardPreferences() async {
    try {
      // Scope preferences by selected router if available
      final routerId = _routerService?.selectedRouter?.id;
      final key = routerId != null
          ? 'dashboard_preferences:$routerId'
          : 'dashboard_preferences';

      // Try router-specific key first
      String? json = await _secureStorageService.readValue(key);
      // Backward-compat: if missing, fall back to global key
      if ((json == null || json.isEmpty) && routerId != null) {
        json = await _secureStorageService.readValue('dashboard_preferences');
      }
      if (json != null && json.isNotEmpty) {
        _dashboardPreferences = DashboardPreferences.fromJson(jsonDecode(json));
        notifyListeners();
      }
    } catch (e, stack) {
      Logger.exception('Failed to load dashboard preferences', e, stack);
      _dashboardPreferences = DashboardPreferences();
    }
  }

  Future<void> saveDashboardPreferences(DashboardPreferences prefs) async {
    try {
      _dashboardPreferences = prefs;
      final routerId = _routerService?.selectedRouter?.id;
      final key = routerId != null
          ? 'dashboard_preferences:$routerId'
          : 'dashboard_preferences';
      await _secureStorageService.writeValue(key, jsonEncode(prefs.toJson()));
      notifyListeners();
    } catch (e, stack) {
      Logger.exception('Failed to save dashboard preferences', e, stack);
      rethrow;
    }
  }

  String? get sysauth => _authService?.sysauth;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void setError(String error) {
    _errorMessage = error;
    notifyListeners();
  }

  Map<String, dynamic>? get dashboardData => _dashboardData;
  NlbwmonSnapshot? get nlbwmonSnapshot => _nlbwmonSnapshot;
  bool get isNlbwmonAvailable => _isNlbwmonAvailable;
  bool get isNlbwmonLoading => _isNlbwmonLoading;
  String? get nlbwmonError => _nlbwmonError;
  List<double> get rxHistory => _throughputService?.rxHistory ?? [];
  List<double> get txHistory => _throughputService?.txHistory ?? [];
  double get currentRxRate => _throughputService?.currentRxRate ?? 0.0;
  double get currentTxRate => _throughputService?.currentTxRate ?? 0.0;
  bool get isDashboardLoading => _isDashboardLoading;
  String? get dashboardError => _dashboardError;

  // Interface-specific throughput getters
  List<double> getRxHistoryForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getRxHistoryForInterface(deviceName ?? interface) ?? [];
  }

  List<double> getTxHistoryForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getTxHistoryForInterface(deviceName ?? interface) ?? [];
  }

  double getCurrentRxRateForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getCurrentRxRateForInterface(deviceName ?? interface) ?? 0.0;
  }

  double getCurrentTxRateForInterface(String interface) {
    final deviceName = _getDeviceNameForInterface(interface);
    return _throughputService?.getCurrentTxRateForInterface(deviceName ?? interface) ?? 0.0;
  }

  Future<void> loadRouters() async {
    await _routerService?.loadRouters();
    notifyListeners();
  }

  Future<void> addRouter(model.Router router) async {
    await _routerService?.addRouter(router);
    notifyListeners();
  }

  Future<void> removeRouter(String id) async {
    if (_routerService == null) return;

    // Get the router before removing to clear its certificates
    final router = _routerService!.routers.firstWhere(
      (r) => r.id == id,
      orElse: () => throw Exception('Router not found'),
    );

    // Clear certificates for this specific router
    await _httpClientManager.clearCertificatesForHost(router.ipAddress);

    final needsSwitch = await _routerService!.removeRouter(id);
    if (needsSwitch && _routerService!.routers.isNotEmpty) {
      await selectRouter(_routerService!.routers.first.id);
    } else if (_routerService!.selectedRouter == null) {
      _dashboardData = null;
      _clearNlbwmonData();
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  Future<void> selectRouter(String id, {BuildContext? context}) async {
    if (_routerService == null || _routerService!.routers.isEmpty) return;

    final found = _routerService!.selectRouter(id);
    if (found == null) return;

    _isLoading = true;
    _dashboardError = null;
    _clearNlbwmonData();

    // Clear throughput data when switching routers to prevent mixing data from different routers
    _cancelThroughputTimer();

    // Determine a safe context before any awaits
    final safeContext = context?.mounted == true ? context : null; // ignore: use_build_context_synchronously

    // Load router-scoped dashboard preferences immediately on selection
    await loadDashboardPreferences();

    notifyListeners();
    // ignore: use_build_context_synchronously
    final loginSuccess = await login(
      found.ipAddress,
      found.username,
      found.password,
      found.useHttps,
      fromRouter: true,
      context: safeContext, // ignore: use_build_context_synchronously
    );
    if (loginSuccess) {
      await fetchDashboardData();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateRouter(model.Router router) async {
    await _routerService?.updateRouter(router);
    notifyListeners();
  }

  Future<bool> login(
    String ip,
    String user,
    String pass,
    bool useHttps, {
    bool fromRouter = false,
    BuildContext? context,
  }) async {
    _isLoading = true;
    _errorMessage = null;

    // Clear throughput data when logging in to prevent mixing data from different sessions
    _cancelThroughputTimer();

    notifyListeners();

    try {
      await _authService!.login(ip, user, pass, useHttps, context: context);

      // Check if authentication was successful
      if (_authService!.isAuthenticated) {
        // Get the actual protocol used (might be different due to redirect)
        final actualUseHttps = _authService!.useHttps;

        if (!fromRouter) {
          // If not from router selection, add or update router with detected protocol
          if (_routerService != null) {
            final router = _routerService!.createRouter(
              ip,
              user,
              pass,
              actualUseHttps, // Use the detected protocol
            );
            final idx = _routerService!.routers.indexWhere(
              (r) => r.id == router.id,
            );
            if (idx == -1) {
              await addRouter(router);
            } else {
              await updateRouter(router);
            }
          }
        } else if (actualUseHttps != useHttps && _routerService != null) {
          // If we're logging in from a saved router and the protocol changed, update it
          final router = _routerService!.selectedRouter;
          if (router != null) {
            final updatedRouter = router.copyWith(useHttps: actualUseHttps);
            await updateRouter(updatedRouter);
            Logger.info(
              'Updated router protocol from ${useHttps ? "HTTPS" : "HTTP"} to ${actualUseHttps ? "HTTPS" : "HTTP"}',
            );
          }
        }
        await fetchDashboardData();
        _startThroughputTimer();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage =
            'Login Failed: Invalid credentials or host unreachable.';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'An error occurred: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void logout() {
    _authService?.logout().then((_) {});
    _dashboardData = null;
    _dashboardError = null;
    _clearNlbwmonData();
    _cancelThroughputTimer();
    // Optionally, do not clear routers or selectedRouter
    notifyListeners();
  }

  Future<void> fetchDashboardData() async {
    if (_reviewerModeEnabled) {
      // For reviewer mode, return mock data immediately
      _isDashboardLoading = true;
      _dashboardError = null;
      notifyListeners();

      await Future.delayed(
        const Duration(milliseconds: 500),
      ); // Simulate network delay

      try {
        final results = await Future.wait([
          _apiService!.callSimple('system', 'board', {}),
          _apiService!.callSimple('system', 'info', {}),
          _apiService!.callSimple('network', 'device', {}),
          _apiService!.callSimple('network.interface', 'dump', {}),
          _apiService!.callSimple('wireless', 'devices', {}),
          _apiService!.callSimple('luci-rpc', 'getDHCPLeases', {}),
          _apiService!.callSimple('uci', 'get', {'config': 'wireless'}),
        ]);

        final interfaceDump = results[3][1] as Map<String, dynamic>;
        final rawDhcpData = results[5][1] as Map<String, dynamic>;
        final processedDhcpData = _processDhcpLeases(rawDhcpData);

        _dashboardData = {
          'boardInfo': results[0][1],
          'sysInfo': results[1][1],
          'networkDevices': results[2][1],
          'interfaceDump': interfaceDump,
          'wireless': results[4][1],
          'dhcpLeases': processedDhcpData,
          'uciWirelessConfig': results[6][1],
          'wan': _extractWanData(interfaceDump),
          'wireguard': <String, dynamic>{}, // Empty for reviewer mode
          'switchPorts': buildSwitchPortGroups(
            boardJson: {
              'switch': {
                'switch0': {
                  'ports': [
                    {'num': 5, 'device': 'eth0'},
                    {'num': 0, 'role': 'lan', 'index': 1},
                    {'num': 1, 'role': 'lan', 'index': 2},
                    {'num': 2, 'role': 'lan', 'index': 3},
                    {'num': 3, 'role': 'lan', 'index': 4},
                    {'num': 4, 'role': 'wan'},
                  ],
                },
              },
            },
            uciNetworkConfig: const {},
            portStatesBySwitch: {
              'switch0': {
                'result': [
                  {'port': 5, 'link': true, 'speed': 1000, 'duplex': true},
                  {'port': 0, 'link': true, 'speed': 1000, 'duplex': true},
                  {'port': 1, 'link': true, 'speed': 100, 'duplex': true},
                  {'port': 2, 'link': false},
                  {'port': 3, 'link': false},
                  {'port': 4, 'link': false},
                ],
              },
            },
            featuresBySwitch: {
              'switch0': {'switch_title': 'mock-switch'},
            },
          ),
          '_lastUpdated':
              DateTime.now().millisecondsSinceEpoch, // Force UI updates
        };

        await _fetchNlbwmonData(notify: false);

        // Update throughput data with mock network data for reviewer mode
        if (_throughputService != null) {
          final networkData = results[2][1] as Map<String, dynamic>?;
          final wanDeviceNames = {
            'eth0',
            'wlan0',
            'br-lan',
          }; // Mock all devices

          // Check if we should track specific interface
          final prefs = _dashboardPreferences;
          String? specificInterface;
          if (!prefs.showAllThroughput &&
              prefs.primaryThroughputInterface != null) {
            // Map interface name to actual device name
            specificInterface = _getDeviceNameForInterface(
              prefs.primaryThroughputInterface!,
            );
          }

          _throughputService!.updateThroughput(
            networkData,
            wanDeviceNames,
            specificInterface: specificInterface,
          );
        }

        // Start throughput timer for reviewer mode
        _startThroughputTimer();

        // Schedule an immediate throughput update to get initial data faster
        Future.delayed(const Duration(milliseconds: 100), () {
          _updateThroughputOnly();
        });

        _isDashboardLoading = false;
        notifyListeners();
      } catch (e) {
        _dashboardError = 'Failed to fetch dashboard data: $e';
        _isDashboardLoading = false;
        notifyListeners();
      }
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null) {
      return;
    }

    // If already loading, don't start another request (but this shouldn't prevent pull-to-refresh)
    // We'll let the new request proceed and the loading state will be handled properly
    final ip = _routerService!.selectedRouter!.ipAddress;
    final useHttps = _routerService!.selectedRouter!.useHttps;

    _isDashboardLoading = true;
    _dashboardError = null;
    notifyListeners();

    try {
      // Perform all API calls in parallel
      Future<dynamic> callOptionalRpc({
        required String object,
        required String method,
        Map<String, dynamic>? params,
      }) async {
        try {
          return await _apiService!.call(
            ip,
            _authService!.sysauth!,
            useHttps,
            object: object,
            method: method,
            params: params,
          );
        } catch (e, stack) {
          Logger.warning('Optional RPC $object.$method failed: $e');
          Logger.debug('Optional RPC $object.$method stack: $stack');
          return null;
        }
      }

      final wirelessFuture = callOptionalRpc(
        object: 'luci-rpc',
        method: 'getWirelessDevices',
        params: {},
      );

      // UCI wireless config is optional — wired-only routers may not have it
      final uciWirelessFuture = callOptionalRpc(
        object: 'uci',
        method: 'get',
        params: {'config': 'wireless'},
      );

      final boardJsonFuture = callOptionalRpc(
        object: 'luci-rpc',
        method: 'getBoardJSON',
        params: {},
      );

      final uciNetworkFuture = callOptionalRpc(
        object: 'uci',
        method: 'get',
        params: {'config': 'network'},
      );

      final builtinEthernetPortsFuture = callOptionalRpc(
        object: 'luci',
        method: 'getBuiltinEthernetPorts',
        params: {},
      );

      final results = await Future.wait([
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'system',
          method: 'board',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'system',
          method: 'info',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'luci-rpc',
          method: 'getNetworkDevices',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'network.interface',
          method: 'dump',
          params: {},
        ),
        _apiService!.call(
          ip,
          _authService!.sysauth!,
          useHttps,
          object: 'luci-rpc',
          method: 'getDHCPLeases',
          params: {},
        ),
      ]);

      // Helper to safely extract data and handle errors from LuCI's [status, data] responses
      dynamic getData(dynamic result) {
        if (result is List && result.length > 1) {
          if (result[0] == 0) {
            return result[1]; // Success
          } else {
            // Throw an exception with the error message from the API
            final errorMessage = result[1] is String
                ? result[1]
                : 'Unknown API Error';
            throw Exception(errorMessage);
          }
        }
        // Handle cases where the result is not in the expected format
        return result;
      }

      dynamic getOptionalData(dynamic result, String label) {
        try {
          return getData(result);
        } catch (e) {
          Logger.warning('Optional RPC $label returned error: $e');
          return null;
        }
      }

      final boardInfoData = getData(results[0]);
      final sysInfoData = getData(results[1]);
      final networkData = getData(results[2]) as Map<String, dynamic>?;
      final interfaceDump = getData(results[3]) as Map<String, dynamic>?;
      final dhcpLeases = getData(results[4]) as Map<String, dynamic>?;

      // Await optional wireless futures in parallel (won't throw — wired-only routers are fine)
      final optionalResults = await Future.wait([
        wirelessFuture,
        uciWirelessFuture,
        boardJsonFuture,
        uciNetworkFuture,
        builtinEthernetPortsFuture,
      ]);
      final wirelessRaw = optionalResults[0];
      final uciWirelessRaw = optionalResults[1];
      final boardJsonRaw = optionalResults[2];
      final uciNetworkRaw = optionalResults[3];
      final builtinEthernetPortsRaw = optionalResults[4];

      Map<String, dynamic>? wirelessData;
      if (wirelessRaw != null) {
        final parsedWireless =
            getOptionalData(wirelessRaw, 'luci-rpc.getWirelessDevices');
        if (parsedWireless is Map<String, dynamic>) {
          wirelessData = parsedWireless;
        }
      }

      dynamic uciWirelessConfig;
      if (uciWirelessRaw != null) {
        uciWirelessConfig =
            getOptionalData(uciWirelessRaw, 'uci.get wireless');
      }

      dynamic boardJson;
      if (boardJsonRaw != null) {
        boardJson = getOptionalData(boardJsonRaw, 'luci-rpc.getBoardJSON');
      }

      dynamic uciNetworkConfig;
      if (uciNetworkRaw != null) {
        uciNetworkConfig = getOptionalData(uciNetworkRaw, 'uci.get network');
      }

      dynamic builtinEthernetPorts;
      if (builtinEthernetPortsRaw != null) {
        builtinEthernetPorts = getOptionalData(
          builtinEthernetPortsRaw,
          'luci.getBuiltinEthernetPorts',
        );
      }

      final switchNames = extractSwitchNamesFromData(
        boardJson: boardJson,
        uciNetworkConfig: uciNetworkConfig,
      );
      final switchPortStates = <String, dynamic>{};
      final switchFeatures = <String, dynamic>{};
      if (switchNames.isNotEmpty) {
        await Future.wait(
          switchNames.map((switchName) async {
            final featureRaw = await callOptionalRpc(
              object: 'luci',
              method: 'getSwconfigFeatures',
              params: {'switch': switchName},
            );
            if (featureRaw != null) {
              final featureData = getOptionalData(
                featureRaw,
                'luci.getSwconfigFeatures $switchName',
              );
              if (featureData != null) {
                switchFeatures[switchName] = featureData;
              }
            }

            final stateRaw = await callOptionalRpc(
              object: 'luci',
              method: 'getSwconfigPortState',
              params: {'switch': switchName},
            );
            if (stateRaw != null) {
              final stateData = getOptionalData(
                stateRaw,
                'luci.getSwconfigPortState $switchName',
              );
              if (stateData != null) {
                switchPortStates[switchName] = stateData;
              }
            }
          }),
        );
      }

      final swconfigPortGroups = buildSwitchPortGroups(
        boardJson: boardJson,
        uciNetworkConfig: uciNetworkConfig,
        portStatesBySwitch: switchPortStates,
        featuresBySwitch: switchFeatures,
      );
      final hasSwconfigPorts = swconfigPortGroups.any(
        (group) => group.visiblePorts.isNotEmpty,
      );

      final directPortGroup = hasSwconfigPorts
          ? null
          : buildDirectPortGroup(
              builtinPorts: builtinEthernetPorts,
              boardJson: boardJson,
              deviceStatuses: const <String, dynamic>{},
              networkDevices: networkData,
            );
      final switchPortGroups = <SwitchPortGroup>[
        ...swconfigPortGroups,
        if (directPortGroup != null) directPortGroup,
      ];

      // Fetch WireGuard peer information for WireGuard interfaces
      final wireguardData = <String, dynamic>{};
      if (interfaceDump != null && interfaceDump['interface'] is List) {
        // Check if there are any WireGuard interfaces
        final hasWireGuardInterfaces = interfaceDump['interface'].any((
          interface,
        ) {
          if (interface is Map<String, dynamic>) {
            final proto = interface['proto'] as String?;
            return proto == 'wireguard';
          }
          return false;
        });

        if (hasWireGuardInterfaces) {
          // Fetch all WireGuard data at once
          final allWireGuardData = await _apiService!.fetchWireGuardPeers(
            ipAddress: ip,
            sysauth: _authService!.sysauth!,
            useHttps: useHttps,
            interface: '', // Empty string to get all interfaces
          );

          if (allWireGuardData != null) {
            // The new endpoint returns data for all interfaces
            // We need to extract data for each WireGuard interface
            for (final interface in interfaceDump['interface']) {
              if (interface is Map<String, dynamic>) {
                final ifname = interface['interface'] as String?;
                final proto = interface['proto'] as String?;
                if (proto == 'wireguard' && ifname != null) {
                  // Look for this interface in the WireGuard data
                  final interfaceData = allWireGuardData[ifname];

                  if (interfaceData != null) {
                    wireguardData[ifname] = interfaceData;
                  }
                }
              }
            }
          }
        }
      }

      // Throughput calculation - collect ALL interface devices
      final wanDeviceNames = <String>{};
      if (interfaceDump != null && interfaceDump['interface'] is List) {
        for (final interface in interfaceDump['interface']) {
          if (interface is Map<String, dynamic>) {
            final ifname = interface['interface'] as String?;
            // Skip only loopback interface
            if (ifname != null && ifname != 'loopback' && ifname != 'lo') {
              final device = interface['device'] as String?;
              final l3Device = interface['l3_device'] as String?;
              if (device != null) {
                wanDeviceNames.add(device);
              }
              if (l3Device != null && l3Device != device) {
                wanDeviceNames.add(l3Device);
              }
            }
          }
        }
      }

      // Update throughput data using the service
      // Check if we should track specific interface
      final prefs = _dashboardPreferences;
      String? specificInterface;
      if (!prefs.showAllThroughput &&
          prefs.primaryThroughputInterface != null) {
        // Map interface name to actual device name
        specificInterface = _getDeviceNameForInterface(
          prefs.primaryThroughputInterface!,
        );
      }

      _throughputService?.updateThroughput(
        networkData,
        wanDeviceNames,
        specificInterface: specificInterface,
      );

      _dashboardData = {
        'boardInfo': boardInfoData,
        'sysInfo': sysInfoData,
        'networkDevices': networkData,
        'interfaceDump': interfaceDump,
        'wireless': wirelessData ?? <String, dynamic>{},
        'dhcpLeases': dhcpLeases,
        'wan': _extractWanData(interfaceDump),
        'uciWirelessConfig': uciWirelessConfig,
        'wireguard': wireguardData,
        'switchPorts': switchPortGroups,
        '_lastUpdated':
            DateTime.now().millisecondsSinceEpoch, // Force UI updates
      };

      await _fetchNlbwmonData(notify: false);

      // Hybrid approach: update lastKnownHostname for the selected router
      final boardInfo = _dashboardData?['boardInfo'] as Map<String, dynamic>?;
      final hostname = boardInfo?['hostname']?.toString();
      if (hostname != null && hostname.isNotEmpty) {
        await _routerService?.updateSelectedRouterHostname(hostname);
      }

      // Ensure throughput timer is running
      _startThroughputTimer();

      // Schedule an immediate throughput update to get initial data faster
      Future.delayed(const Duration(milliseconds: 100), () {
        _updateThroughputOnly();
      });
    } catch (e) {
      final errorMessage = e.toString();
      if (errorMessage.contains('Access denied')) {
        _dashboardError = 'Access Denied: Check RPC permissions for this user.';
      } else {
        _dashboardError = 'Failed to fetch dashboard data: $e';
      }
      // Log error with stack trace for debugging
      // print('Dashboard fetch error: $e\n$stack');
      // Clear dashboard data when there's an error so we don't show stale data
      _dashboardData = null;
      _clearNlbwmonData();
    } finally {
      _isDashboardLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchNlbwmonData() async {
    await _fetchNlbwmonData(notify: true);
  }

  Future<void> _fetchNlbwmonData({
    bool notify = true,
  }) async {
    if (_reviewerModeEnabled) {
      _isNlbwmonLoading = true;
      _nlbwmonError = null;
      if (notify) notifyListeners();

      await Future.delayed(const Duration(milliseconds: 250));
      _nlbwmonSnapshot = NlbwmonSnapshot.fromActionData(
        _mockNlbwmonTrafficData(),
        periods: const ['2026-07-01'],
      );
      _isNlbwmonAvailable = true;
      _isNlbwmonLoading = false;
      if (notify) notifyListeners();
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null ||
        _apiService == null) {
      _clearNlbwmonData();
      if (notify) notifyListeners();
      return;
    }

    final router = _routerService!.selectedRouter!;
    _isNlbwmonLoading = true;
    _nlbwmonError = null;
    if (notify) notifyListeners();

    try {
      final snapshot = await _fetchNlbwmonSnapshotForRouter(
        router,
        includePeriods: true,
        logFailures: true,
      );
      if (snapshot == null) {
        _nlbwmonSnapshot = null;
        _isNlbwmonAvailable = false;
        _nlbwmonError = 'Bandwidth monitor unavailable';
      } else {
        _nlbwmonSnapshot = snapshot;
        _isNlbwmonAvailable = true;
        _nlbwmonError = null;
      }
    } catch (e, stack) {
      Logger.info('nlbwmon unavailable or failed: $e');
      Logger.debug('nlbwmon stack: $stack');
      _nlbwmonSnapshot = null;
      _isNlbwmonAvailable = false;
      _nlbwmonError = 'Bandwidth monitor unavailable';
    } finally {
      _isNlbwmonLoading = false;
      if (notify) notifyListeners();
    }
  }

  Future<NlbwmonSnapshot?> _fetchNlbwmonSnapshotForRouter(
    model.Router router, {
    bool includePeriods = false,
    _RouterSession? session,
    bool logFailures = false,
  }) async {
    if (_reviewerModeEnabled) {
      return NlbwmonSnapshot.fromActionData(
        _mockNlbwmonTrafficData(),
        periods: includePeriods ? const ['2026-07-01'] : const [],
      );
    }

    if (_apiService == null) return null;

    try {
      final activeSession = session ?? await _sessionForRouter(router);
      if (activeSession == null) return null;

      List<String> periods = const [];
      if (includePeriods) {
        try {
          final periodsData = await _apiService!.execDirect(
            router.ipAddress,
            activeSession.sysauth,
            activeSession.useHttps,
            command: '/usr/libexec/nlbwmon-action',
            params: const ['periods'],
            responseType: 'json',
          );
          if (periodsData is Map && periodsData['periods'] is List) {
            periods = (periodsData['periods'] as List)
                .map((period) => period.toString())
                .toList(growable: false);
          }
        } catch (e, stack) {
          Logger.debug('nlbwmon periods unavailable: $e');
          Logger.debug('nlbwmon periods stack: $stack');
        }
      }

      final trafficData = await _apiService!.execDirect(
        router.ipAddress,
        activeSession.sysauth,
        activeSession.useHttps,
        command: '/usr/libexec/nlbwmon-action',
        params: const [
          'download',
          '-g',
          'family,mac,ip,layer7',
          '-o',
          '-rx_bytes,-tx_bytes',
        ],
        responseType: 'json',
      );

      if (trafficData is! Map) {
        throw const FormatException('Malformed nlbwmon response');
      }

      return NlbwmonSnapshot.fromActionData(
        Map<String, dynamic>.from(trafficData),
        periods: periods,
      );
    } catch (e, stack) {
      if (logFailures) {
        Logger.info('nlbwmon unavailable or failed: $e');
      } else {
        Logger.debug('nlbwmon client discovery unavailable: $e');
      }
      Logger.debug('nlbwmon stack: $stack');
      return null;
    }
  }

  void _clearNlbwmonData() {
    _nlbwmonSnapshot = null;
    _isNlbwmonAvailable = false;
    _isNlbwmonLoading = false;
    _nlbwmonError = null;
  }

  Map<String, dynamic> _mockNlbwmonTrafficData() {
    return {
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
          4,
          'AA:BB:CC:11:22:33',
          '192.168.1.100',
          'https',
          318,
          734003200,
          48210,
          94371840,
          18520,
        ],
        [
          4,
          'AA:BB:CC:44:55:66',
          '192.168.1.101',
          'youtube',
          91,
          524288000,
          38400,
          41943040,
          9100,
        ],
        [
          6,
          'AA:BB:CC:11:22:33',
          'fd00::100',
          'dns',
          52,
          10485760,
          1100,
          5242880,
          900,
        ],
        [
          4,
          'AA:BB:CC:77:88:99',
          '192.168.1.222',
          'ssh',
          22,
          8388608,
          720,
          1048576,
          140,
        ],
      ],
    };
  }

  Map<String, dynamic> _processDhcpLeases(Map<String, dynamic> rawDhcpData) {
    final stdout = rawDhcpData['stdout'] as String? ?? '';
    final leases = <Map<String, dynamic>>[];

    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) continue;

      final parts = line.trim().split(' ');
      if (parts.length >= 5) {
        // Format: timestamp mac_address ip_address hostname client_id
        final timestamp = int.tryParse(parts[0]) ?? 0;
        final macAddress = parts[1];
        final ipAddress = parts[2];
        final hostname = parts[3];

        leases.add({
          'expires': timestamp,
          'macaddr': macAddress,
          'ipaddr': ipAddress,
          'hostname': hostname,
          'activetime': 0, // Default for mock data
          'leasetime': timestamp,
        });
      }
    }

    return {'dhcp_leases': leases};
  }

  Map<String, dynamic>? _extractWanData(Map<String, dynamic>? interfaceDump) {
    if (interfaceDump == null || interfaceDump['interface'] == null) {
      return null;
    }
    try {
      for (var interface in interfaceDump['interface']) {
        if (interface['route'] is List) {
          for (var route in interface['route']) {
            if (route is Map &&
                route['target'] == '0.0.0.0' &&
                route['mask'] == 0) {
              return interface;
            }
          }
        }
      }
    } catch (e) {
      // print('WAN data extraction error: $e');
      return null;
    }
    return null;
  }

  String? _getDeviceNameForInterface(String interfaceName) {
    // Handle wireless format: "SSID (deviceName)"
    if (interfaceName.contains('(')) {
      final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceName);
      return match?.group(1);
    }
    
    // Map interface names to their actual device names from interface dump
    final interfaceDump = _dashboardData?['interfaceDump'] as Map<String, dynamic>?;
    if (interfaceDump != null && interfaceDump['interface'] is List) {
      for (final interface in interfaceDump['interface']) {
        if (interface is Map<String, dynamic>) {
          final ifname = interface['interface'] as String?;
          if (ifname == interfaceName) {
            // Return the device or l3_device field
            return (interface['device'] ?? interface['l3_device']) as String?;
          }
        }
      }
    }
    
    // If not found in interface dump, check if it's already a device name
    // (e.g., eth0, br-lan, wlan0)
    return interfaceName;
  }

  void _startThroughputTimer() {
    _throughputTimer?.cancel();
    // Don't start timer if we're rebooting
    if (_isRebooting) {
      return;
    }
    _throughputTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _updateThroughputOnly();
    });
  }

  /// Updates only throughput data without refetching the entire dashboard
  Future<void> _updateThroughputOnly() async {
    // Don't try to update throughput during reboot
    if (_isRebooting) {
      return;
    }

    if (_reviewerModeEnabled) {
      // For reviewer mode, get network devices data only
      try {
        final result = await _apiService!.callSimple('network', 'device', {});
        final networkData = result[1] as Map<String, dynamic>?;
        final wanDeviceNames = {'eth0'}; // Mock WAN device

        // Check if we should track specific interface
        final prefs = _dashboardPreferences;
        String? specificInterface;
        if (!prefs.showAllThroughput &&
            prefs.primaryThroughputInterface != null) {
          // Extract device name from interface ID (format: "SSID (deviceName)" or just "deviceName")
          final interfaceId = prefs.primaryThroughputInterface!;
          if (interfaceId.contains('(')) {
            // Wireless format: "SSID (deviceName)"
            final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceId);
            specificInterface = match?.group(1);
          } else {
            // Wired format: just device name
            specificInterface = interfaceId;
          }
        }

        _throughputService?.updateThroughput(
          networkData,
          wanDeviceNames,
          specificInterface: specificInterface,
        );
        notifyListeners();
      } catch (e) {
        // Don't log throughput update errors as they're non-critical
      }
      return;
    }

    if (_routerService?.selectedRouter == null ||
        _authService?.sysauth == null) {
      return;
    }

    final ip = _routerService!.selectedRouter!.ipAddress;
    final useHttps = _routerService!.selectedRouter!.useHttps;

    try {
      // Only fetch network devices for throughput calculation
      final result = await _apiService!.call(
        ip,
        _authService!.sysauth!,
        useHttps,
        object: 'luci-rpc',
        method: 'getNetworkDevices',
        params: {},
      );

      if (result is List && result.length > 1 && result[0] == 0) {
        final networkData = result[1] as Map<String, dynamic>?;

        // Get ALL device names from cached dashboard data (except loopback)
        final wanDeviceNames = <String>{};
        final interfaceDump =
            _dashboardData?['interfaceDump'] as Map<String, dynamic>?;
        if (interfaceDump != null && interfaceDump['interface'] is List) {
          for (final interface in interfaceDump['interface']) {
            if (interface is Map<String, dynamic>) {
              final ifname = interface['interface'] as String?;
              final device = interface['device'] as String?;
              final l3Device = interface['l3_device'] as String?;
              // Include all interfaces except loopback
              if (ifname != null && ifname != 'loopback' && ifname != 'lo') {
                if (device != null) wanDeviceNames.add(device);
                if (l3Device != null && l3Device != device) {
                  wanDeviceNames.add(l3Device);
                }
              }
            }
          }
        }

        // Check if we should track specific interface
        final prefs = _dashboardPreferences;
        String? specificInterface;
        if (!prefs.showAllThroughput &&
            prefs.primaryThroughputInterface != null) {
          // Extract device name from interface ID (format: "SSID (deviceName)" or just "deviceName")
          final interfaceId = prefs.primaryThroughputInterface!;
          if (interfaceId.contains('(')) {
            // Wireless format: "SSID (deviceName)"
            final match = RegExp(r'\(([^)]+)\)').firstMatch(interfaceId);
            specificInterface = match?.group(1);
          } else {
            // Wired format: just device name
            specificInterface = interfaceId;
          }
        }

        _throughputService?.updateThroughput(
          networkData,
          wanDeviceNames,
          specificInterface: specificInterface,
        );
        notifyListeners();
      }
    } catch (e) {
      // Don't log throughput update errors as they're non-critical
    }
  }

  void _cancelThroughputTimer() {
    _throughputTimer?.cancel();
    _throughputService?.clear();
  }

  Future<bool> reboot({BuildContext? context}) async {
    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    // Cancel throughput timer before starting reboot to prevent "client closed" errors
    _cancelThroughputTimer();

    _isRebooting = true;
    notifyListeners();

    try {
      final result = await _apiService!.reboot(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        context: context,
      );
      // Wait 30 seconds before starting to poll for router availability
      // Some routers take longer to reboot
      Future.delayed(const Duration(seconds: 30), () {
        _pollRouterAvailability();
      });
      return result;
    } catch (e) {
      _isRebooting = false;
      notifyListeners();
      return false;
    }
  }

  void _pollRouterAvailability() {
    // Reset poll attempts
    _pollAttempts = 0;
    _pollingTimer?.cancel();

    // Start polling with exponential backoff
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    if (_pollAttempts >= _maxPollAttempts) {
      // Max attempts reached, stop polling
      _isRebooting = false;
      notifyListeners();
      // print('[Reboot] Timeout: Router did not come back online after $_maxPollAttempts attempts');

      // Show a user-friendly message
      if (onRouterBackOnline != null) {
        // Reuse the callback to show timeout message
        onRouterBackOnline!();
      }
      return;
    }

    // Calculate delay with exponential backoff: 3s, 3s, 5s, 8s, 12s, 18s, then 20s intervals
    int delaySeconds;
    if (_pollAttempts < 2) {
      delaySeconds = 3;
    } else if (_pollAttempts < 4) {
      delaySeconds = 5;
    } else if (_pollAttempts < 6) {
      delaySeconds = 8;
    } else if (_pollAttempts < 8) {
      delaySeconds = 12;
    } else if (_pollAttempts < 10) {
      delaySeconds = 18;
    } else {
      delaySeconds = 20; // Cap at 20 seconds for remaining attempts
    }

    _pollingTimer = Timer(Duration(seconds: delaySeconds), () async {
      _pollAttempts++;
      final available = await _pingRouter();

      if (available) {
        // Router is back online
        _pollingTimer?.cancel();
        _pollingTimer = null;
        _isRebooting = false;
        _pollAttempts = 0;
        notifyListeners();

        // Notify UI that router is back online
        if (onRouterBackOnline != null) {
          onRouterBackOnline!();
        }

        // Force relogin
        if (_routerService?.selectedRouter != null) {
          await login(
            _routerService!.selectedRouter!.ipAddress,
            _routerService!.selectedRouter!.username,
            _routerService!.selectedRouter!.password,
            _routerService!.selectedRouter!.useHttps,
          );
        }
      } else {
        // Schedule next poll
        _scheduleNextPoll();
      }
    });
  }

  Future<bool> _pingRouter() async {
    if (_authService?.ipAddress == null) return false;

    // Clear cached HTTP clients for this host to avoid stale connections
    if (_pollAttempts == 0) {
      _httpClientManager.disposeClient(
        _authService!.ipAddress!,
        _authService!.useHttps,
      );
    }

    // Try multiple endpoints in order
    final scheme = _authService!.useHttps ? 'https' : 'http';
    final endpoints = [
      '/', // Root
      '/cgi-bin/luci/', // LuCI login page
      '/cgi-bin/luci/admin', // Admin page
    ];

    for (final endpoint in endpoints) {
      try {
        final url = '$scheme://${_authService!.ipAddress}$endpoint';

        // Create a fresh Dio client for pinging to avoid certificate/connection issues
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            sendTimeout: const Duration(seconds: 5),
            followRedirects: false,
            validateStatus: (code) => code != null && code >= 200 && code < 500,
          ),
        );

        if (_authService!.useHttps) {
          final adapter = IOHttpClientAdapter();
          adapter.createHttpClient = () {
            final httpClient = HttpClient();
            httpClient.connectionTimeout = const Duration(seconds: 5);
            // Accept any cert for ping only
            httpClient.badCertificateCallback = (cert, host, port) => true;
            return httpClient;
          };
          dio.httpClientAdapter = adapter;
        }

        // print('[Ping] Attempt $_pollAttempts: Checking $url');
        final response = await dio.get(url);
        // print('[Ping] Response from $endpoint: ${response.statusCode}');

        // Accept various status codes as "alive"
        final isAlive = response.statusCode != null &&
            response.statusCode! >= 200 &&
            response.statusCode! < 500;

        if (isAlive) {
          if (_pollAttempts > 5) {
            // If we've been polling for a while and get a response,
            // wait a bit more to ensure services are fully started
            await Future.delayed(const Duration(seconds: 5));
          }
          return true;
        }
      } catch (e) {
        // Try next endpoint
        if (endpoint == endpoints.last) {
          // print('[Ping] All endpoints failed on attempt $_pollAttempts');
          // print('[Ping] Last error: ${e.toString()}');

          if (e is SocketException) {
            // print('[Ping] Socket error: ${e.message}, OS Error: ${e.osError}');
          } else if (e is HandshakeException) {
            // print('[Ping] SSL handshake error - router may still be starting');
          }
        }
      }
    }

    return false;
  }

  Future<bool> checkRouterAvailability() async {
    if (_reviewerModeEnabled || _authService?.ipAddress == null) {
      return _reviewerModeEnabled;
    }
    return await _authService!.checkRouterAvailability(
      _authService!.ipAddress!,
      _authService!.useHttps,
    );
  }

  Future<bool> setWirelessRadioState(
    String device,
    bool enabled, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      // Simulate operation for reviewer mode
      await Future.delayed(const Duration(milliseconds: 500));
      await fetchDashboardData();
      return true;
    }

    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    try {
      // 1. Set the disabled state
      final setResult = await _apiService!.uciSet(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        config: 'wireless',
        section: device,
        values: {'disabled': enabled ? '0' : '1'},
        context: context,
      );
      if (!_isRpcSuccess(setResult)) {
        Logger.warning(
          'Failed to set wireless radio state: '
          '${_formatDebugValue(setResult)}',
        );
        return false;
      }

      final applied = await _applySelectedRouterConfigChanges(
        'wireless',
        context: context,
      );
      if (!applied) return false;

      // Refresh dashboard data to reflect the change
      await fetchDashboardData();

      return true;
    } catch (e) {
      _dashboardError = 'Failed to toggle Wi-Fi: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateWirelessInterfaceSettings({
    required String section,
    required bool enabled,
    required String ssid,
    String? password,
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      await Future.delayed(const Duration(milliseconds: 500));
      await fetchDashboardData();
      return true;
    }

    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    final trimmedSsid = ssid.trim();
    if (section.trim().isEmpty || trimmedSsid.isEmpty) {
      return false;
    }

    final values = <String, String>{
      'ssid': trimmedSsid,
      'disabled': enabled ? '0' : '1',
    };
    final trimmedPassword = password?.trim();
    if (trimmedPassword != null && trimmedPassword.isNotEmpty) {
      values['key'] = trimmedPassword;
      values['encryption'] = 'psk2';
    }

    try {
      final setResult = await _apiService!.uciSet(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        config: 'wireless',
        section: section,
        values: values,
        context: context,
      );
      if (!_isRpcSuccess(setResult)) {
        Logger.warning(
          'Failed to set Wi-Fi settings: ${_formatDebugValue(setResult)}',
        );
        return false;
      }

      final applied = await _applySelectedRouterConfigChanges(
        'wireless',
        context: context,
      );
      if (!applied) return false;

      await fetchDashboardData();
      return true;
    } catch (e, stack) {
      Logger.exception('Failed to update Wi-Fi settings', e, stack);
      _dashboardError = 'Failed to update Wi-Fi settings: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _applySelectedRouterConfigChanges(
    String config, {
    BuildContext? context,
  }) async {
    if (_authService?.sysauth == null || _authService?.ipAddress == null) {
      return false;
    }

    try {
      final applyResult = await _apiService!.call(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        object: 'uci',
        method: 'apply',
        params: {'rollback': false},
        context: context?.mounted == true ? context : null,
      );
      if (_isRpcSuccess(applyResult)) {
        return true;
      }
      Logger.warning(
        'uci.apply failed for $config: ${_formatDebugValue(applyResult)}',
      );
    } catch (e, stack) {
      Logger.exception('uci.apply failed for $config', e, stack);
    }

    try {
      final commitResult = await _apiService!.uciCommit(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        config: config,
        context: context?.mounted == true ? context : null,
      );
      if (!_isRpcSuccess(commitResult)) {
        Logger.warning(
          'uci.commit failed for $config: ${_formatDebugValue(commitResult)}',
        );
        return false;
      }

      final reloadResult = await _apiService!.call(
        _authService!.ipAddress!,
        _authService!.sysauth!,
        _authService!.useHttps,
        object: 'uci',
        method: 'reload_config',
        params: const <String, dynamic>{},
        context: context?.mounted == true ? context : null,
      );
      if (!_isRpcSuccess(reloadResult)) {
        Logger.warning(
          'uci.reload_config failed for $config: '
          '${_formatDebugValue(reloadResult)}',
        );
        return false;
      }
      return true;
    } catch (e, stack) {
      Logger.exception('Config apply fallback failed for $config', e, stack);
      return false;
    }
  }

  Future<bool> tryAutoLogin({BuildContext? context}) async {
    if (_reviewerModeEnabled) {
      return await _authService!.tryAutoLogin(
        null,
        null,
        null,
        null,
        context: context,
      );
    }
    return await _authService?.tryAutoLogin(
          null,
          null,
          null,
          null,
          context: context,
        ) ??
        false;
  }

  Future<List<Client>> fetchBlockedClients({BuildContext? context}) async {
    try {
      final routers = _routerService?.routers ?? const <model.Router>[];
      final blockedRules = await _fetchBlockedRuleMapForRouters(
        routers,
        context: context,
      );
      Logger.info(
        'Blocked clients view found ${blockedRules.length} app-created '
        'rules across ${routers.length} routers',
      );
      final activeClients = await fetchAggregatedClients();
      final clients = <String, Client>{};

      for (final client in activeClients) {
        final mac = _normalizeClientMac(client.macAddress);
        if (client.isBlocked || blockedRules.containsKey(mac)) {
          final rule = blockedRules[mac];
          final router = rule?.router;
          clients[mac] = client.copyWith(
            isBlocked: true,
            ipAddress: client.ipAddress == 'N/A' ? rule?.ipAddress : null,
            hostname: client.hostname == 'Unknown' ? rule?.hostname : null,
            routerId: client.routerId ?? router?.id,
            routerName: client.routerName ??
                (router == null ? null : _routerDisplayName(router)),
          );
        }
      }

      for (final rule in blockedRules.values) {
        clients.putIfAbsent(
          rule.macAddress,
          () => Client.blocked(
            macAddress: rule.macAddress,
            ipAddress: rule.ipAddress,
            hostname: rule.hostname,
            routerId: rule.router?.id,
            routerName:
                rule.router == null ? null : _routerDisplayName(rule.router!),
          ),
        );
      }

      final list = clients.values.toList();
      list.sort((a, b) {
        final routerCompare = (a.routerName ?? '').compareTo(b.routerName ?? '');
        if (routerCompare != 0) return routerCompare;
        return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
      });
      return list;
    } catch (e, stack) {
      Logger.exception('Failed to fetch blocked clients', e, stack);
      return [];
    }
  }

  Future<bool> blockClient(Client client, {BuildContext? context}) async {
    if (!_isBlockableMac(client.macAddress)) {
      Logger.warning(
        'Block client rejected: invalid MAC "${client.macAddress}"',
      );
      return false;
    }
    final mac = _normalizeClientMac(client.macAddress);

    if (_reviewerModeEnabled) {
      Logger.info('Reviewer mode block client: mac=$mac');
      _mockBlockedClientMacs.add(mac);
      notifyListeners();
      return true;
    }

    final router = _routerForClient(client);
    if (router == null) {
      Logger.warning(
        'Block client rejected: no target router for mac=$mac '
        'clientRouterId=${client.routerId ?? 'none'}',
      );
      return false;
    }

    try {
      final session = await _sessionForRouter(router, context: context);
      if (session == null) {
        Logger.warning(
          'Block client failed: could not authenticate router='
          '${router.ipAddress} mac=$mac',
        );
        return false;
      }

      final section = _blockRuleSectionForMac(mac);
      final name = _blockRuleNameForMac(mac);
      Logger.info(
        'Creating client block rule router=${router.ipAddress} '
        'mac=$mac section=$section',
      );
      final existingRules = await _fetchBlockedRulesForRouter(
        router,
        context: context,
      );
      final deleteSections = {
        section,
        for (final rule in existingRules)
          if (rule.macAddress == mac && _isSafeUciSection(rule.section))
            rule.section,
      };

      for (final deleteSection in deleteSections.where(_isSafeUciSection)) {
        await _deleteFirewallSection(
          router,
          session,
          deleteSection,
          context: context,
        );
      }

      final addResult = await _callRouterUci(
        router,
        session,
        'add',
        {
          'config': 'firewall',
          'type': 'rule',
          'name': section,
          'values': _firewallBlockRuleValues(
            client: client,
            mac: mac,
            name: name,
          ),
        },
        context: context,
      );

      if (!_isRpcSuccess(addResult)) {
        Logger.warning(
          'Block client failed while adding UCI rule router='
          '${router.ipAddress} mac=$mac result=${_formatDebugValue(addResult)}',
        );
        return false;
      }

      final success = await _applyFirewallChanges(
        router,
        session,
        context: context,
      );
      if (success) {
        notifyListeners();
      } else {
        Logger.warning(
          'Block client failed while applying firewall changes '
          'router=${router.ipAddress} mac=$mac',
        );
      }
      return success;
    } catch (e, stack) {
      Logger.exception('Failed to block client', e, stack);
      return false;
    }
  }

  Future<bool> unblockClient(Client client, {BuildContext? context}) async {
    if (!_isBlockableMac(client.macAddress)) {
      Logger.warning(
        'Unblock client rejected: invalid MAC "${client.macAddress}"',
      );
      return false;
    }
    final mac = _normalizeClientMac(client.macAddress);

    if (_reviewerModeEnabled) {
      Logger.info('Reviewer mode unblock client: mac=$mac');
      _mockBlockedClientMacs.remove(mac);
      notifyListeners();
      return true;
    }

    final router = _routerForClient(client);
    if (router == null) {
      Logger.warning(
        'Unblock client rejected: no target router for mac=$mac '
        'clientRouterId=${client.routerId ?? 'none'}',
      );
      return false;
    }

    try {
      final session = await _sessionForRouter(router, context: context);
      if (session == null) {
        Logger.warning(
          'Unblock client failed: could not authenticate router='
          '${router.ipAddress} mac=$mac',
        );
        return false;
      }

      final section = _blockRuleSectionForMac(mac);
      Logger.info(
        'Removing client block rule router=${router.ipAddress} '
        'mac=$mac section=$section',
      );
      final existingRules = await _fetchBlockedRulesForRouter(
        router,
        context: context,
      );
      final deleteSections = {
        section,
        for (final rule in existingRules)
          if (rule.macAddress == mac && _isSafeUciSection(rule.section))
            rule.section,
      };

      var removedAnySection = false;
      for (final deleteSection in deleteSections.where(_isSafeUciSection)) {
        final removed = await _deleteFirewallSection(
          router,
          session,
          deleteSection,
          context: context,
        );
        removedAnySection = removedAnySection || removed;
      }

      if (!removedAnySection) {
        Logger.info('No client block rules found to remove for mac=$mac');
        return true;
      }

      final success = await _applyFirewallChanges(
        router,
        session,
        context: context,
      );
      if (success) {
        notifyListeners();
      } else {
        Logger.warning(
          'Unblock client failed while applying firewall changes '
          'router=${router.ipAddress} mac=$mac',
        );
      }
      return success;
    } catch (e, stack) {
      Logger.exception('Failed to unblock client', e, stack);
      return false;
    }
  }

  String _normalizeClientMac(String mac) {
    final hex = mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hex.length == 12) {
      final pairs = <String>[];
      for (var i = 0; i < hex.length; i += 2) {
        pairs.add(hex.substring(i, i + 2).toUpperCase());
      }
      return pairs.join(':');
    }
    return mac.trim().toUpperCase().replaceAll('-', ':');
  }

  String _blockIdForMac(String mac) {
    return mac.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  }

  bool _isBlockableMac(String mac) {
    return _blockIdForMac(mac).length == 12;
  }

  String _blockRuleNameForMac(String mac) {
    return '$_blockedRuleNamePrefix${_blockIdForMac(mac)}';
  }

  String _blockRuleSectionForMac(String mac) {
    return '$_blockedRuleSectionPrefix${_blockIdForMac(mac)}';
  }

  String _routerDisplayName(model.Router router) {
    final name = router.lastKnownHostname ?? '';
    return name.isNotEmpty ? name : router.ipAddress;
  }

  model.Router? _routerForClient(Client client) {
    final routers = _routerService?.routers ?? const <model.Router>[];
    if (client.routerId != null) {
      for (final router in routers) {
        if (router.id == client.routerId) return router;
      }
    }
    return _routerService?.selectedRouter;
  }

  Map<String, String> _firewallBlockRuleValues({
    required Client client,
    required String mac,
    required String name,
  }) {
    final values = {
      'name': name,
      'src': '*',
      'dest': '*',
      'src_mac': mac,
      'proto': 'all',
      'target': 'REJECT',
      'family': 'any',
      'enabled': '1',
    };
    values[_blockedRuleHostnameOption] =
        _blockedMetadataValue(client.hostname) ?? 'Unknown';
    values[_blockedRuleIpOption] =
        _blockedMetadataValue(client.ipAddress) ?? 'N/A';
    return values;
  }

  String? _blockedMetadataValue(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  Future<dynamic> _callRouterUci(
    model.Router router,
    _RouterSession session,
    String method,
    Map<String, dynamic> params, {
    BuildContext? context,
  }) async {
    Logger.debug(
      'Calling uci.$method router=${router.ipAddress} '
      'params=${_formatDebugValue(params)}',
    );
    final result = await _apiService!.call(
      router.ipAddress,
      session.sysauth,
      session.useHttps,
      object: 'uci',
      method: method,
      params: params,
      context: context?.mounted == true ? context : null,
    );
    Logger.debug(
      'uci.$method result router=${router.ipAddress} '
      'result=${_formatDebugValue(result)}',
    );
    return result;
  }

  Future<bool> _deleteFirewallSection(
    model.Router router,
    _RouterSession session,
    String section, {
    BuildContext? context,
  }) async {
    final result = await _callRouterUci(
      router,
      session,
      'delete',
      {
        'config': 'firewall',
        'section': section,
      },
      context: context,
    );
    if (_isRpcSuccess(result)) {
      Logger.debug(
        'Deleted firewall section router=${router.ipAddress} section=$section',
      );
      return true;
    }
    Logger.debug(
      'Firewall section was not deleted router=${router.ipAddress} '
      'section=$section result=${_formatDebugValue(result)}',
    );
    return false;
  }

  Future<bool> _applyFirewallChanges(
    model.Router router,
    _RouterSession session, {
    BuildContext? context,
  }) async {
    try {
      final applyResult = await _callRouterUci(
        router,
        session,
        'apply',
        {'rollback': false},
        context: context,
      );
      if (_isRpcSuccess(applyResult)) {
        return true;
      }
      Logger.warning(
        'uci.apply failed router=${router.ipAddress} '
        'result=${_formatDebugValue(applyResult)}',
      );
    } catch (e, stack) {
      Logger.exception('uci.apply failed', e, stack);
    }

    try {
      final commitResult = await _callRouterUci(
        router,
        session,
        'commit',
        {'config': 'firewall'},
        context: context,
      );
      if (!_isRpcSuccess(commitResult)) {
        Logger.warning(
          'uci.commit firewall failed router=${router.ipAddress} '
          'result=${_formatDebugValue(commitResult)}',
        );
        return false;
      }

      final reloadResult = await _callRouterUci(
        router,
        session,
        'reload_config',
        const <String, dynamic>{},
        context: context,
      );
      if (!_isRpcSuccess(reloadResult)) {
        Logger.warning(
          'uci.reload_config failed router=${router.ipAddress} '
          'result=${_formatDebugValue(reloadResult)}',
        );
        return false;
      }

      return true;
    } catch (e, stack) {
      Logger.exception('Firewall commit/reload fallback failed', e, stack);
      return false;
    }
  }

  bool _isSafeUciSection(String section) {
    return RegExp(r'^[A-Za-z0-9_]+$').hasMatch(section);
  }

  dynamic _rpcData(dynamic result) {
    if (result is List && result.length > 1 && result[0] == 0) {
      return result[1];
    }
    return result;
  }

  bool _isRpcSuccess(dynamic result) {
    if (result is List && result.isNotEmpty) {
      if (result[0] != 0) return false;
      if (result.length < 2) return true;
      final data = result[1];
      if (data is Map && data['code'] != null) {
        return data['code'].toString() == '0';
      }
      return true;
    }
    return result != null;
  }

  String _formatDebugValue(dynamic value) {
    final text = value.toString();
    const maxLength = 2000;
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...<truncated>';
  }

  Map<String, dynamic> _toStringKeyedMap(Map<dynamic, dynamic> map) {
    return map.map((key, value) => MapEntry(key.toString(), value));
  }

  Map<String, dynamic> _firewallSectionsFromUciData(dynamic data) {
    final rpcData = _rpcData(data);
    if (rpcData is! Map) return {};

    final map = _toStringKeyedMap(rpcData);
    if (map['values'] is Map) {
      return _toStringKeyedMap(map['values'] as Map);
    }
    if (map['firewall'] is Map) {
      return _toStringKeyedMap(map['firewall'] as Map);
    }
    return map;
  }

  List<String> _macsFromFirewallValue(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value.map((entry) => _normalizeClientMac(entry.toString())).toList();
    }
    return value
        .toString()
        .split(RegExp(r'[\s,]+'))
        .map((entry) => _normalizeClientMac(entry))
        .where(_isBlockableMac)
        .toList();
  }

  List<_BlockedClientRule> _extractBlockedClientRules(
    dynamic data, {
    model.Router? router,
  }) {
    final sections = _firewallSectionsFromUciData(data);
    final rules = <_BlockedClientRule>[];

    sections.forEach((section, rawValue) {
      if (rawValue is! Map) return;
      final value = _toStringKeyedMap(rawValue);
      final type = value['.type']?.toString() ?? value['type']?.toString();
      final name = value['name']?.toString() ?? section;
      final isAppRule = name.startsWith(_blockedRuleNamePrefix) ||
          section.startsWith(_blockedRuleSectionPrefix);
      if (type != null && type != 'rule') return;
      if (!isAppRule) return;

      final hostname = _blockedMetadataValue(
        value[_blockedRuleHostnameOption]?.toString(),
      );
      final ipAddress = _blockedMetadataValue(
        value[_blockedRuleIpOption]?.toString(),
      );
      if (hostname == null || ipAddress == null) return;
      for (final mac in _macsFromFirewallValue(value['src_mac'])) {
        if (!_isBlockableMac(mac)) continue;
        rules.add(
          _BlockedClientRule(
            macAddress: _normalizeClientMac(mac),
            section: section,
            ipAddress: ipAddress,
            hostname: hostname,
            router: router,
          ),
        );
      }
    });

    return rules;
  }

  Future<_RouterSession?> _sessionForRouter(
    model.Router router, {
    BuildContext? context,
  }) async {
    final selected = _routerService?.selectedRouter;
    if (selected?.id == router.id && _authService?.sysauth != null) {
      return _RouterSession(
        sysauth: _authService!.sysauth!,
        useHttps: _authService!.useHttps,
      );
    }

    if (_apiService is RealApiService) {
      final real = _apiService as RealApiService;
      final result = await real.loginWithProtocolDetection(
        router.ipAddress,
        router.username,
        router.password,
        router.useHttps,
        context: context,
      );
      if (result.token != null) {
        return _RouterSession(
          sysauth: result.token!,
          useHttps: result.actualUseHttps,
        );
      }
    }

    return null;
  }

  Future<List<_BlockedClientRule>> _fetchBlockedRulesForRouter(
    model.Router router, {
    BuildContext? context,
  }) async {
    final session = await _sessionForRouter(router, context: context);
    if (session == null) return const [];

    try {
      final result = await _apiService!.call(
        router.ipAddress,
        session.sysauth,
        session.useHttps,
        object: 'uci',
        method: 'get',
        params: {'config': 'firewall'},
        context: context?.mounted == true ? context : null,
      );
      return _extractBlockedClientRules(result, router: router);
    } catch (e, stack) {
      Logger.exception('Failed to fetch blocked client rules', e, stack);
      return const [];
    }
  }

  Future<Map<String, _BlockedClientRule>> _fetchBlockedRuleMapForRouters(
    List<model.Router> routers, {
    BuildContext? context,
  }) async {
    if (_reviewerModeEnabled) {
      final router = _routerService?.selectedRouter;
      return {
        for (final mac in _mockBlockedClientMacs)
          _normalizeClientMac(mac): _BlockedClientRule(
            macAddress: _normalizeClientMac(mac),
            section: _blockRuleSectionForMac(mac),
            ipAddress: 'N/A',
            hostname: 'Blocked Device',
            router: router,
          ),
      };
    }

    final tasks = routers.map(
      (router) => _fetchBlockedRulesForRouter(router, context: context),
    );
    final results = await Future.wait(tasks);
    final rules = <String, _BlockedClientRule>{};
    for (final routerRules in results) {
      for (final rule in routerRules) {
        rules[rule.macAddress] = rule;
      }
    }
    return rules;
  }

  Map<String, Map<String, dynamic>> _indexStationDetailsByMac(
    Map<String, List<Map<String, dynamic>>> stationsMap,
  ) {
    final indexed = <String, Map<String, dynamic>>{};
    stationsMap.forEach((interface, stations) {
      for (final station in stations) {
        final rawMac = (station['mac'] ?? station['macaddr'])?.toString();
        if (rawMac == null || rawMac.isEmpty) continue;

        final mac = _normalizeClientMac(rawMac);
        final detail = Map<String, dynamic>.from(station);
        detail['mac'] = mac;
        detail['macaddr'] = mac;
        detail['interface'] ??= interface;
        indexed[mac] = detail;
      }
    });
    return indexed;
  }

  Set<String> _lowercaseMacsFromStationDetails(
    Map<String, List<Map<String, dynamic>>> stationsMap,
  ) {
    return _indexStationDetailsByMac(
      stationsMap,
    ).keys.map((mac) => mac.toLowerCase()).toSet();
  }

  Map<String, dynamic> _leaseWithStationDetails(
    Map<String, dynamic> lease,
    Map<String, dynamic>? stationDetails,
  ) {
    if (stationDetails == null) return lease;

    final merged = Map<String, dynamic>.from(lease);
    merged.addAll(stationDetails);
    merged['macaddr'] =
        lease['macaddr'] ?? stationDetails['macaddr'] ?? stationDetails['mac'];
    return merged;
  }

  ConnectionType _connectionTypeForDhcpLease(
    Client leaseClient, {
    required bool isWireless,
  }) {
    if (isWireless) return ConnectionType.wireless;
    if (leaseClient.connectionType == ConnectionType.wireless) {
      return ConnectionType.unknown;
    }
    if (leaseClient.connectionType == ConnectionType.unknown) {
      return ConnectionType.wired;
    }
    return leaseClient.connectionType;
  }

  bool _isUsableNlbwmonClientMac(String mac) {
    final id = _blockIdForMac(mac);
    if (id.length != 12 ||
        id == '000000000000' ||
        id == 'ffffffffffff') {
      return false;
    }
    final firstOctet = int.tryParse(id.substring(0, 2), radix: 16);
    return firstOctet != null && (firstOctet & 1) == 0;
  }

  bool _routerAddressMatchesClientIp(String routerAddress, String clientIp) {
    final normalized = routerAddress.contains('://')
        ? routerAddress
        : 'http://$routerAddress';
    final host = Uri.tryParse(normalized)?.host ?? routerAddress;
    return host == clientIp;
  }

  Future<List<_NlbwmonClientHost>> _fetchNlbwmonClientHostsForRouters(
    List<model.Router> routers,
  ) async {
    if (_reviewerModeEnabled) {
      final router =
          routers.isNotEmpty ? routers.first : _routerService?.selectedRouter;
      final snapshot = NlbwmonSnapshot.fromActionData(
        _mockNlbwmonTrafficData(),
      );
      return snapshot.hosts
          .map((usage) => _NlbwmonClientHost(usage: usage, router: router))
          .toList(growable: false);
    }

    if (routers.isEmpty) return const [];

    final selected = _routerService?.selectedRouter;
    if (routers.length == 1 &&
        selected?.id == routers.first.id &&
        _nlbwmonSnapshot != null) {
      return _nlbwmonSnapshot!.hosts
          .map(
            (usage) => _NlbwmonClientHost(
              usage: usage,
              router: routers.first,
            ),
          )
          .toList(growable: false);
    }

    final tasks = routers.map((router) async {
      final snapshot = await _fetchNlbwmonSnapshotForRouter(router);
      if (snapshot == null) return const <_NlbwmonClientHost>[];
      return snapshot.hosts
          .map((usage) => _NlbwmonClientHost(usage: usage, router: router))
          .toList(growable: false);
    });

    final results = await Future.wait(tasks);
    return results.expand((hosts) => hosts).toList(growable: false);
  }

  void _mergeNlbwmonHostsIntoClients({
    required Map<String, Client> clients,
    required Iterable<_NlbwmonClientHost> nlbwmonHosts,
    required Map<String, Map<String, dynamic>> wirelessDetails,
    required Map<String, _BlockedClientRule> blockedRules,
  }) {
    for (final source in nlbwmonHosts) {
      final rawMac = source.usage.macAddress;
      final ipAddress = source.usage.ipAddress?.trim();
      if (rawMac == null ||
          ipAddress == null ||
          ipAddress.isEmpty ||
          !_isUsableNlbwmonClientMac(rawMac)) {
        continue;
      }

      final mac = _normalizeClientMac(rawMac);
      final stationDetails = wirelessDetails[mac];
      final isWireless = stationDetails != null;
      final blockedRule = blockedRules[mac];
      final router = source.router;
      if (router != null &&
          _routerAddressMatchesClientIp(router.ipAddress, ipAddress)) {
        continue;
      }
      final routerName = router == null ? null : _routerDisplayName(router);
      final existing = clients[mac];

      if (existing != null) {
        final existingHasIp =
            existing.ipAddress.trim().isNotEmpty && existing.ipAddress != 'N/A';
        clients[mac] = existing.copyWith(
          ipAddress: existingHasIp ? existing.ipAddress : ipAddress,
          connectionType:
              isWireless ? ConnectionType.wireless : existing.connectionType,
          isBlocked: existing.isBlocked || blockedRule != null,
          routerId: existing.routerId ?? router?.id,
          routerName: existing.routerName ?? routerName,
        );
        continue;
      }

      final lease = <String, dynamic>{
        'ipaddr': ipAddress,
        'macaddr': mac,
        'hostname': blockedRule?.hostname ?? 'Unknown',
        if (router != null) 'routerId': router.id,
        if (routerName != null) 'routerName': routerName,
      };
      final client = Client.fromLease(
        _leaseWithStationDetails(lease, stationDetails),
      );
      clients[mac] = client.copyWith(
        connectionType:
            isWireless ? ConnectionType.wireless : ConnectionType.unknown,
        isBlocked: blockedRule != null,
      );
    }
  }

  bool _shouldReplaceClient(Client current, Client candidate) {
    if (!current.hasWirelessMetrics && candidate.hasWirelessMetrics) {
      return true;
    }
    if (current.hasWirelessMetrics && !candidate.hasWirelessMetrics) {
      return false;
    }
    return candidate.hostname.isNotEmpty &&
        candidate.hostname.length > current.hostname.length;
  }

  /// Fetch all associated wireless MAC addresses from all wireless interfaces
  Future<Set<String>> fetchAllAssociatedWirelessMacs() async {
    if (_reviewerModeEnabled) {
      // Use the interface method for mock/reviewer mode
      final stationsMap = await _apiService!.fetchAssociatedStationDetails();
      return _lowercaseMacsFromStationDetails(stationsMap);
    } else {
      // Use the context-aware method for real API calls
      if (_routerService?.selectedRouter == null ||
          _authService?.sysauth == null) {
        return {};
      }

      final ip = _routerService!.selectedRouter!.ipAddress;
      final useHttps = _routerService!.selectedRouter!.useHttps;

      final stationsMap = await _apiService!
          .fetchAllAssociatedStationDetailsWithContext(
            ipAddress: ip,
            sysauth: _authService!.sysauth!,
            useHttps: useHttps,
          );
      return _lowercaseMacsFromStationDetails(stationsMap);
    }
  }

  @override
  void dispose() {
    _throughputTimer?.cancel();
    _pollingTimer?.cancel();
    _pollAttempts = 0;
    _isRebooting = false;
    super.dispose();
  }

  /// Aggregates DHCP leases across all configured routers and classifies clients
  /// as wireless if their MAC appears in any router's associated stations list.
  Future<List<Client>> fetchAggregatedClients() async {
    try {
      final routers = _routerService?.routers ?? const <model.Router>[];
      // Build a union of wireless station details across all routers
      final wirelessDetails = await fetchAssociatedStationDetailsAggregated();
      final normalizedWireless = wirelessDetails.keys.toSet();
      final blockedRules = await _fetchBlockedRuleMapForRouters(
        routers,
      );

      // Aggregate leases across routers
      final leases = await fetchAggregatedDhcpLeases();

      // Convert to Client models with connection type
      final clients = <String, Client>{}; // key by normalized MAC
      for (final lease in leases) {
        final rawClient = Client.fromLease(lease);
        final macNorm = _normalizeClientMac(rawClient.macAddress);
        final stationDetails = wirelessDetails[macNorm];
        final isWireless =
            rawClient.connectionType != ConnectionType.wired &&
            normalizedWireless.contains(macNorm);
        final client = Client.fromLease(
          _leaseWithStationDetails(
            lease,
            isWireless ? stationDetails : null,
          ),
        );
        final enriched = client.copyWith(
          connectionType: _connectionTypeForDhcpLease(
            rawClient,
            isWireless: isWireless,
          ),
          isBlocked: blockedRules.containsKey(macNorm),
        );
        // Prefer entries that have more info.
        final existing = clients[macNorm];
        if (existing == null || _shouldReplaceClient(existing, enriched)) {
          clients[macNorm] = enriched;
        }
      }

      // Add wireless stations not in DHCP leases (AP-mode fallback)
      for (final mac in normalizedWireless) {
        if (!clients.containsKey(mac)) {
          clients[mac] = Client.fromWirelessStation(
            mac,
            stationDetails: wirelessDetails[mac],
            isBlocked: blockedRules.containsKey(mac),
          );
        }
      }

      final nlbwmonHosts = await _fetchNlbwmonClientHostsForRouters(routers);
      _mergeNlbwmonHostsIntoClients(
        clients: clients,
        nlbwmonHosts: nlbwmonHosts,
        wirelessDetails: wirelessDetails,
        blockedRules: blockedRules,
      );

      // Sort: wireless > wired > unknown, then by hostname
      final list = clients.values.toList();
      list.sort((a, b) {
        int typeOrder(ConnectionType t) {
          switch (t) {
            case ConnectionType.wireless:
              return 0;
            case ConnectionType.wired:
              return 1;
            default:
              return 2;
          }
        }

        final cmpType =
            typeOrder(a.connectionType).compareTo(typeOrder(b.connectionType));
        if (cmpType != 0) return cmpType;
        return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
      });
      return list;
    } catch (e, stack) {
      Logger.exception('Failed to aggregate clients', e, stack);
      return [];
    }
  }

  /// Returns clients for the currently selected router only
  Future<List<Client>> fetchClientsForSelectedRouter() async {
    try {
      if (_reviewerModeEnabled) {
        final stationsMap = await _apiService!.fetchAssociatedStationDetails();
        final wirelessDetails = _indexStationDetailsByMac(stationsMap);
        final selectedRouter = _routerService?.selectedRouter;
        final blockedRules = await _fetchBlockedRuleMapForRouters(
          selectedRouter == null ? const [] : [selectedRouter],
        );
        final result = await _apiService!.callSimple(
          'luci-rpc',
          'getDHCPLeases',
          {},
        );
        final leases = <Map<String, dynamic>>[];
        if (result is List && result.length > 1 && result[0] == 0) {
          final data = result[1] as Map<String, dynamic>;
          leases.addAll(
            (data['dhcp_leases'] as List<dynamic>? ?? [])
                .cast<Map<String, dynamic>>(),
          );
        }
        // Normalize wireless MACs for consistent lookup
        final normalizedMacs = wirelessDetails.keys.toSet();
        final clientMap = <String, Client>{};
        for (final l in leases) {
          final lease = {
            ...l,
            if (selectedRouter != null) 'routerId': selectedRouter.id,
            if (selectedRouter != null)
              'routerName': _routerDisplayName(selectedRouter),
          };
          final rawClient = Client.fromLease(lease);
          final macNorm = _normalizeClientMac(rawClient.macAddress);
          final isWireless =
              rawClient.connectionType != ConnectionType.wired &&
              normalizedMacs.contains(macNorm);
          final c = Client.fromLease(
            _leaseWithStationDetails(
              lease,
              isWireless ? wirelessDetails[macNorm] : null,
            ),
          );
          clientMap[macNorm] = c.copyWith(
            connectionType: _connectionTypeForDhcpLease(
              rawClient,
              isWireless: isWireless,
            ),
            isBlocked: blockedRules.containsKey(macNorm),
          );
        }
        // Add wireless stations not in DHCP leases (AP-mode fallback)
        for (final mac in normalizedMacs) {
          if (!clientMap.containsKey(mac)) {
            clientMap[mac] = Client.fromWirelessStation(
              mac,
              stationDetails: wirelessDetails[mac],
              isBlocked: blockedRules.containsKey(mac),
              routerId: selectedRouter?.id,
              routerName:
                  selectedRouter == null ? null : _routerDisplayName(selectedRouter),
            );
          }
        }
        final nlbwmonHosts = await _fetchNlbwmonClientHostsForRouters(
          selectedRouter == null ? const [] : [selectedRouter],
        );
        _mergeNlbwmonHostsIntoClients(
          clients: clientMap,
          nlbwmonHosts: nlbwmonHosts,
          wirelessDetails: wirelessDetails,
          blockedRules: blockedRules,
        );
        final reviewerClients = clientMap.values.toList();
        reviewerClients.sort((a, b) {
          int typeOrder(ConnectionType t) {
            switch (t) {
              case ConnectionType.wireless:
                return 0;
              case ConnectionType.wired:
                return 1;
              default:
                return 2;
            }
          }
          final cmpType =
              typeOrder(a.connectionType).compareTo(typeOrder(b.connectionType));
          if (cmpType != 0) return cmpType;
          return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
        });
        return reviewerClients;
      }

      if (_routerService?.selectedRouter == null || _authService?.sysauth == null) {
        return [];
      }
      final router = _routerService!.selectedRouter!;

      // Get wireless station details for this router
      final stationsMap = await _apiService!.fetchAllAssociatedStationDetailsWithContext(
        ipAddress: router.ipAddress,
        sysauth: _authService!.sysauth!,
        useHttps: router.useHttps,
      );
      final wirelessDetails = _indexStationDetailsByMac(stationsMap);
      final blockedRules = await _fetchBlockedRuleMapForRouters([router]);

      // Get DHCP leases for this router
      final callRes = await _apiService!.call(
        router.ipAddress,
        _authService!.sysauth!,
        router.useHttps,
        object: 'luci-rpc',
        method: 'getDHCPLeases',
        params: {},
      );
      final leases = <Map<String, dynamic>>[];
      if (callRes is List && callRes.length > 1 && callRes[0] == 0) {
        final data = callRes[1] as Map<String, dynamic>;
        leases.addAll(
          (data['dhcp_leases'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>(),
        );
      }

      // Normalize wireless MACs for consistent lookup
      final normalizedWireless = wirelessDetails.keys.toSet();

      final clientMap = <String, Client>{};
      for (final l in leases) {
        final lease = {
          ...l,
          'routerId': router.id,
          'routerName': _routerDisplayName(router),
        };
        final rawClient = Client.fromLease(lease);
        final macNorm = _normalizeClientMac(rawClient.macAddress);
        final isWireless =
            rawClient.connectionType != ConnectionType.wired &&
            normalizedWireless.contains(macNorm);
        final c = Client.fromLease(
          _leaseWithStationDetails(
            lease,
            isWireless ? wirelessDetails[macNorm] : null,
          ),
        );
        clientMap[macNorm] = c.copyWith(
          connectionType: _connectionTypeForDhcpLease(
            rawClient,
            isWireless: isWireless,
          ),
          isBlocked: blockedRules.containsKey(macNorm),
        );
      }

      // Add wireless stations not in DHCP leases (AP-mode fallback)
      for (final mac in normalizedWireless) {
        if (!clientMap.containsKey(mac)) {
          clientMap[mac] = Client.fromWirelessStation(
            mac,
            stationDetails: wirelessDetails[mac],
            isBlocked: blockedRules.containsKey(mac),
            routerId: router.id,
            routerName: _routerDisplayName(router),
          );
        }
      }

      final nlbwmonHosts = await _fetchNlbwmonClientHostsForRouters([router]);
      _mergeNlbwmonHostsIntoClients(
        clients: clientMap,
        nlbwmonHosts: nlbwmonHosts,
        wirelessDetails: wirelessDetails,
        blockedRules: blockedRules,
      );

      final clients = clientMap.values.toList();

      // Sort similar to aggregated
      clients.sort((a, b) {
        int typeOrder(ConnectionType t) {
          switch (t) {
            case ConnectionType.wireless:
              return 0;
            case ConnectionType.wired:
              return 1;
            default:
              return 2;
          }
        }

        final cmpType =
            typeOrder(a.connectionType).compareTo(typeOrder(b.connectionType));
        if (cmpType != 0) return cmpType;
        return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
      });
      return clients;
    } catch (e, stack) {
      Logger.exception('Failed to fetch clients for selected router', e, stack);
      return [];
    }
  }

  /// Returns a union set of associated wireless MAC addresses across all routers
  Future<Set<String>> fetchAllAssociatedWirelessMacsAggregated() async {
    final stationDetails = await fetchAssociatedStationDetailsAggregated();
    return stationDetails.keys.map((mac) => mac.toLowerCase()).toSet();
  }

  /// Returns associated wireless station details across all configured routers.
  Future<Map<String, Map<String, dynamic>>>
      fetchAssociatedStationDetailsAggregated() async {
    try {
      if (_reviewerModeEnabled) {
        final stationsMap = await _apiService!.fetchAssociatedStationDetails();
        return _indexStationDetailsByMac(stationsMap);
      }

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return {};

      final tasks = routers.map((r) async {
        try {
          if (_apiService is RealApiService) {
            final real = _apiService as RealApiService;
            final res = await real.loginWithProtocolDetection(
              r.ipAddress,
              r.username,
              r.password,
              r.useHttps,
            );
            if (res.token == null) return <String, Map<String, dynamic>>{};
            final map =
                await _apiService!.fetchAllAssociatedStationDetailsWithContext(
              ipAddress: r.ipAddress,
              sysauth: res.token!,
              useHttps: res.actualUseHttps,
            );
            final withRouter = map.map((interface, stations) {
              return MapEntry(
                interface,
                stations
                    .map(
                      (station) => {
                        ...station,
                        'routerId': r.id,
                        'routerName': _routerDisplayName(r),
                      },
                    )
                    .toList(),
              );
            });
            return _indexStationDetailsByMac(withRouter);
          }
        } catch (e) {
          // Skip router on failure
        }
        return <String, Map<String, dynamic>>{};
      }).toList();

      final results = await Future.wait(tasks);
      return results.fold<Map<String, Map<String, dynamic>>>(
        <String, Map<String, dynamic>>{},
        (acc, details) => acc..addAll(details),
      );
    } catch (e, stack) {
      Logger.exception('Failed to aggregate wireless station details', e, stack);
      return {};
    }
  }

  /// Returns a combined list of DHCP lease maps from all routers
  Future<List<Map<String, dynamic>>> fetchAggregatedDhcpLeases() async {
    try {
      if (_reviewerModeEnabled) {
        // Use mock data
        final result = await _apiService!.callSimple('luci-rpc', 'getDHCPLeases', {});
        if (result is List && result.length > 1 && result[0] == 0) {
          final data = result[1] as Map<String, dynamic>;
          final leases = (data['dhcp_leases'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          final router = _routerService?.selectedRouter;
          return leases
              .map(
                (lease) => {
                  ...lease,
                  if (router != null) 'routerId': router.id,
                  if (router != null) 'routerName': _routerDisplayName(router),
                },
              )
              .toList();
        }
        return [];
      }

      final routers = _routerService?.routers ?? const <model.Router>[];
      if (routers.isEmpty) return [];

      final tasks = routers.map((r) async {
        try {
          if (_apiService is RealApiService) {
            final real = _apiService as RealApiService;
            final res = await real.loginWithProtocolDetection(
              r.ipAddress,
              r.username,
              r.password,
              r.useHttps,
            );
            if (res.token == null) return <Map<String, dynamic>>[];
            final callRes = await _apiService!.call(
              r.ipAddress,
              res.token!,
              res.actualUseHttps,
              object: 'luci-rpc',
              method: 'getDHCPLeases',
              params: {},
            );
            if (callRes is List && callRes.length > 1 && callRes[0] == 0) {
              final data = callRes[1] as Map<String, dynamic>;
              final leases = (data['dhcp_leases'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
              return leases
                  .map(
                    (lease) => {
                      ...lease,
                      'routerId': r.id,
                      'routerName': _routerDisplayName(r),
                    },
                  )
                  .toList();
            }
          }
        } catch (e) {
          // Skip router on failure
        }
        return <Map<String, dynamic>>[];
      }).toList();

      final results = await Future.wait(tasks);
      // Deduplicate by MAC + IP
      final seen = <String, Map<String, dynamic>>{};
      for (final list in results) {
        for (final lease in list) {
          final mac = (lease['macaddr']?.toString() ?? '').toUpperCase();
          final ip = lease['ipaddr']?.toString() ?? '';
          final key = '$mac|$ip';
          if (!seen.containsKey(key)) {
            seen[key] = lease;
          }
        }
      }
      return seen.values.toList();
    } catch (e, stack) {
      Logger.exception('Failed to aggregate DHCP leases', e, stack);
      return [];
    }
  }
}
