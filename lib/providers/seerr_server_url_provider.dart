import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/util/fladder_config.dart';

/// Resolves the Seerr base URL for the current network state.
///
/// Precedence: reachable local URL, deployment preset, account server URL.
String resolveSeerrServerUrl({
  required String? presetServerUrl,
  required String serverUrl,
  required String localServerUrl,
  required bool localAvailable,
}) {
  final local = localServerUrl.trim();
  if (localAvailable && local.isNotEmpty) return local;
  final preset = presetServerUrl?.trim() ?? '';
  if (preset.isNotEmpty) return preset;
  return serverUrl.trim();
}

final seerrServerUrlProvider = Provider<String>((ref) {
  final credentials = ref.watch(userProvider.select((value) => value?.seerrCredentials));
  return resolveSeerrServerUrl(
    presetServerUrl: FladderConfig.seerrBaseUrl,
    serverUrl: credentials?.serverUrl ?? '',
    localServerUrl: credentials?.localServerUrl ?? '',
    localAvailable: ref.watch(seerrLocalConnectionAvailableProvider),
  );
});
