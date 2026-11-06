import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/services/local_network_permission.dart';

part 'connectivity_provider.g.dart';

enum ConnectionState {
  offline,
  mobile,
  wifi,
  ethernet,
  vpn;

  bool get homeInternet => switch (this) {
        ConnectionState.offline => false,
        ConnectionState.mobile => false,
        ConnectionState.wifi => true,
        ConnectionState.ethernet => true,
        ConnectionState.vpn => true,
      };
}

final offlineStateProvider = Provider<bool>((ref) {
  final isLoggedIn = ref.watch(userProvider.select((value) => value != null));
  return ref.watch(connectivityStatusProvider.select((value) => value == ConnectionState.offline)) && isLoggedIn;
});

final localConnectionAvailableProvider = StateProvider<bool>((ref) => false);

/// Result of the last probe of the account's local Seerr URL, plus whether a
/// request against that URL has since been rejected.
typedef SeerrLocalProbe = ({String url, bool reachable, bool rejected});

final seerrLocalProbeProvider = StateProvider<SeerrLocalProbe>(
  (ref) => (url: '', reachable: false, rejected: false),
);

/// Whether the local Seerr URL configured right now may be used for requests.
///
/// The probe result only counts for the URL it was run against, and a rejection
/// recorded against that URL outranks a reachable probe: reachability cannot tell
/// an instance that rejects our credentials from a healthy one.
final seerrLocalConnectionAvailableProvider = Provider<bool>((ref) {
  final localUrl = ref.watch(userProvider.select((value) => value?.seerrCredentials?.localServerUrl.trim() ?? ''));
  final probe = ref.watch(seerrLocalProbeProvider);
  return localUrl.isNotEmpty && probe.url == localUrl && probe.reachable && !probe.rejected;
});

@Riverpod(keepAlive: true)
class ConnectivityStatus extends _$ConnectivityStatus {
  Timer? _debounceTimer;
  int _probeId = 0;
  Completer<void>? _probeCompleter;
  Completer<void>? _seerrProbeCompleter;
  DateTime? _lastProbe;

  @override
  ConnectionState build() {
    ref.listen(
      userProvider.select((value) => (
            value?.id,
            value?.credentials.localUrl,
            value?.seerrCredentials?.localServerUrl,
            value?.seerrCredentials?.apiKey,
            value?.seerrCredentials?.sessionCookie,
            // A fingerprint, because the map itself compares by identity and a
            // rejection must be cleared when the headers that caused it change.
            (value?.seerrCredentials?.customHeaders ?? const <String, String>{})
                .entries
                .map((entry) => '${entry.key}=${entry.value}')
                .join('&'),
          )),
      (previous, next) {
        if (previous == next) return;
        // Another account, a different Seerr URL or a changed credential set makes
        // the previous probe result - including a rejection - meaningless.
        final seerrChanged = previous?.$1 != next.$1 ||
            previous?.$3 != next.$3 ||
            previous?.$4 != next.$4 ||
            previous?.$5 != next.$5 ||
            previous?.$6 != next.$6;
        if (seerrChanged) {
          ref.read(seerrLocalProbeProvider.notifier).state = (url: '', reachable: false, rejected: false);
        }
        checkConnectivity(immediate: true);
      },
    );

    final subscription = Connectivity().onConnectivityChanged.listen((results) {
      _handleHardwareChange(results);
    });

    ref.onDispose(() {
      _debounceTimer?.cancel();
      subscription.cancel();
      _probeId++;
      _resolveProbe();
      _resolveSeerrProbe();
    });

    checkConnectivity(immediate: true);

    return ConnectionState.mobile;
  }

  Future<void> checkConnectivity({bool immediate = false}) async {
    final results = await Connectivity().checkConnectivity();
    _handleHardwareChange(results, immediate: immediate);
  }

  Future<void> checkConnectivityThrottled() async {
    final lastProbe = _lastProbe;
    if (lastProbe != null && DateTime.now().difference(lastProbe) < const Duration(seconds: 30)) return;
    return checkConnectivity(immediate: true);
  }

  Future<void> waitForProbe() async => _probeCompleter?.future;

  /// Waits for the Seerr probe that is already queued for the current network
  /// state, so a request does not route on a superseded result. Returns
  /// immediately when no probe is pending (nothing to wait for).
  Future<void> waitForSeerrProbe() async => _seerrProbeCompleter?.future;

  void _handleHardwareChange(List<ConnectivityResult> results, {bool immediate = false}) {
    final hardwareState = _parseHardwareState(results);

    if (hardwareState == ConnectionState.offline) {
      _debounceTimer?.cancel();
      _probeId++;
      _resolveProbe();
      _resolveSeerrProbe();
      _updateState(ConnectionState.offline, isLocal: false);
      ref.read(seerrLocalProbeProvider.notifier).state = (url: '', reachable: false, rejected: false);
      return;
    }

    _queueProbe(hardwareState, immediate: immediate);
  }

  void _queueProbe(ConnectionState candidateState, {bool immediate = false}) {
    _debounceTimer?.cancel();
    final id = ++_probeId;
    _probeCompleter ??= Completer<void>();
    _seerrProbeCompleter ??= Completer<void>();

    if (immediate) {
      unawaited(_probeReachability(id, candidateState));
    } else {
      _debounceTimer = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(_probeReachability(id, candidateState)),
      );
    }
  }

  Future<void> _probeReachability(int id, ConnectionState candidateState) async {
    _lastProbe = DateTime.now();
    // The Seerr probe runs alongside the Jellyfin checks and resolves its own
    // barrier when it finishes; Jellyfin requests must not wait for it.
    unawaited(_probeSeerrLocal(id));
    try {
      final user = ref.read(userProvider);
      if (user == null) return;

      final localUrl = user.credentials.localUrl;
      if (localUrl != null && localUrl.isNotEmpty) {
        final permission = await checkLocalNetworkPermission();
        if (permission == LocalNetworkPermissionStatus.granted) {
          final localConnection = await fetchSystemInfoDynamic(normalizeUrl(localUrl));

          if (_probeId != id) return;

          if (localConnection?.id == user.credentials.serverId) {
            _updateState(candidateState, isLocal: true);
            return;
          }
        }
      }

      if (_probeId != id) return;

      final remoteUrl = user.credentials.url;
      if (remoteUrl.isNotEmpty) {
        final checkServer = await fetchSystemInfoDynamic(normalizeUrl(remoteUrl));

        if (_probeId != id) return;

        if (checkServer != null) {
          _updateState(candidateState, isLocal: false);
          return;
        }
      }

      if (_probeId == id) {
        _updateState(ConnectionState.offline, isLocal: false);
      }
    } finally {
      if (_probeId == id) {
        _resolveProbe();
      }
    }
  }

  Future<void> _probeSeerrLocal(int id) async {
    var localUrl = '';
    var reachable = false;
    try {
      localUrl = ref.read(userProvider)?.seerrCredentials?.localServerUrl.trim() ?? '';
      if (localUrl.isNotEmpty) {
        final permission = await checkLocalNetworkPermission();
        if (permission == LocalNetworkPermissionStatus.granted) {
          reachable = await fetchSeerrStatusDynamic(normalizeUrl(localUrl));
        }
      }
    } catch (e) {
      log('Seerr local probe failed: $e');
    }
    if (_probeId != id) return;

    // A rejection recorded against this same URL survives the probe: a reachable
    // status endpoint cannot tell an instance that rejects our credentials from a
    // healthy one, so letting the probe clear it would flap every probe cycle.
    final previous = ref.read(seerrLocalProbeProvider);
    ref.read(seerrLocalProbeProvider.notifier).state = (
      url: localUrl,
      reachable: reachable,
      rejected: previous.url == localUrl && previous.rejected,
    );
    _resolveSeerrProbe();
  }

  void _resolveSeerrProbe() {
    if (!(_seerrProbeCompleter?.isCompleted ?? true)) {
      _seerrProbeCompleter?.complete();
    }
    _seerrProbeCompleter = null;
  }

  void _updateState(ConnectionState newState, {required bool isLocal}) {
    ref.read(localConnectionAvailableProvider.notifier).state = isLocal;
    state = newState;
  }

  void _resolveProbe() {
    if (!(_probeCompleter?.isCompleted ?? true)) {
      _probeCompleter?.complete();
    }
    _probeCompleter = null;
  }

  ConnectionState _parseHardwareState(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.vpn)) return ConnectionState.vpn;
    if (results.contains(ConnectivityResult.ethernet)) return ConnectionState.ethernet;
    if (results.contains(ConnectivityResult.wifi)) return ConnectionState.wifi;
    if (results.contains(ConnectivityResult.mobile)) return ConnectionState.mobile;
    return ConnectionState.offline;
  }
}

Future<PublicSystemInfo?> fetchSystemInfoDynamic(String baseUrl) async {
  if (baseUrl.isEmpty) return null;
  try {
    final uri = buildServerUriFromBase(baseUrl, pathSegments: const ['System', 'Info', 'Public']);
    if (uri == null) return null;

    final response = await http.get(uri).timeout(const Duration(seconds: 2));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return PublicSystemInfo.fromJson(jsonDecode(response.body));
    }
    return null;
  } catch (e) {
    log(e.toString());
    return null;
  }
}
