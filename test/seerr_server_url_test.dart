import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/seerr_server_url_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/util/fladder_config.dart';

class _FakeUser extends User {
  _FakeUser(this.account);

  final AccountModel? account;

  @override
  AccountModel? build() => account;
}

AccountModel _account({
  String serverUrl = 'https://seerr.example.com',
  String localServerUrl = '',
}) =>
    AccountModel(
      name: 'tester',
      id: 'user-1',
      avatar: '',
      lastUsed: DateTime(2026, 1, 1),
      credentials: CredentialsModel.internal(
        token: 'token',
        url: 'https://jellyfin.example.com',
        serverId: 'server-1',
      ),
      seerrCredentials: SeerrCredentialsModel(serverUrl: serverUrl, localServerUrl: localServerUrl),
    );

void main() {
  setUp(() => FladderConfig.seerrBaseUrl = null);
  tearDown(() => FladderConfig.seerrBaseUrl = null);

  group('resolveSeerrServerUrl', () {
    test('reachable local URL wins over preset and server URL', () {
      expect(
        resolveSeerrServerUrl(
          presetServerUrl: 'https://preset.example.com',
          serverUrl: 'https://seerr.example.com',
          localServerUrl: 'http://192.168.1.10:5055',
          localAvailable: true,
        ),
        'http://192.168.1.10:5055',
      );
    });

    test('unreachable local URL falls through to the preset', () {
      expect(
        resolveSeerrServerUrl(
          presetServerUrl: 'https://preset.example.com',
          serverUrl: 'https://seerr.example.com',
          localServerUrl: 'http://192.168.1.10:5055',
          localAvailable: false,
        ),
        'https://preset.example.com',
      );
    });

    test('available but empty local URL falls through to the preset', () {
      expect(
        resolveSeerrServerUrl(
          presetServerUrl: 'https://preset.example.com',
          serverUrl: 'https://seerr.example.com',
          localServerUrl: '   ',
          localAvailable: true,
        ),
        'https://preset.example.com',
      );
    });

    test('without a preset the configured server URL is used', () {
      expect(
        resolveSeerrServerUrl(
          presetServerUrl: null,
          serverUrl: ' https://seerr.example.com ',
          localServerUrl: 'http://192.168.1.10:5055',
          localAvailable: false,
        ),
        'https://seerr.example.com',
      );
    });

    test('empty inputs resolve to an empty string', () {
      expect(
        resolveSeerrServerUrl(
          presetServerUrl: null,
          serverUrl: '',
          localServerUrl: '',
          localAvailable: false,
        ),
        '',
      );
    });
  });

  group('seerrServerUrlProvider', () {
    const localUrl = 'http://192.168.1.10:5055';

    ProviderContainer containerWith({SeerrLocalProbe? probe}) {
      final container = ProviderContainer(
        overrides: [
          userProvider.overrideWith(() => _FakeUser(_account(localServerUrl: localUrl))),
          if (probe != null) seerrLocalProbeProvider.overrideWith((ref) => probe),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('uses the local URL while the probe for it succeeded', () {
      final container = containerWith(probe: (url: localUrl, reachable: true, rejected: false));
      expect(container.read(seerrServerUrlProvider), localUrl);
    });

    test('ignores a probe result recorded for another URL', () {
      final container = containerWith(probe: (url: 'http://192.168.1.99:5055', reachable: true, rejected: false));
      expect(container.read(seerrServerUrlProvider), 'https://seerr.example.com');
    });

    test('ignores the local URL after a rejection for it', () {
      final container = containerWith(probe: (url: localUrl, reachable: true, rejected: true));
      expect(container.read(seerrServerUrlProvider), 'https://seerr.example.com');
    });

    test('uses the preset when the local URL is not available', () {
      FladderConfig.seerrBaseUrl = 'https://preset.example.com';

      final container = containerWith(probe: (url: localUrl, reachable: false, rejected: false));
      expect(container.read(seerrServerUrlProvider), 'https://preset.example.com');
    });

    test('re-resolves when local availability flips', () {
      final container = containerWith();

      expect(container.read(seerrServerUrlProvider), 'https://seerr.example.com');

      container.read(seerrLocalProbeProvider.notifier).state = (url: localUrl, reachable: true, rejected: false);
      expect(container.read(seerrServerUrlProvider), localUrl);
    });
  });

  group('setSeerrLocalServerUrl', () {
    test('normalizes a scheme-less LAN address and clears on empty input', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [
          userProvider.overrideWith(() => _FakeUser(_account())),
          sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs)),
        ],
      );
      addTearDown(container.dispose);

      container.read(userProvider.notifier).setSeerrLocalServerUrl(' 192.168.1.10:5055 ');
      expect(container.read(userProvider)?.seerrCredentials?.localServerUrl, 'http://192.168.1.10:5055');

      container.read(userProvider.notifier).setSeerrLocalServerUrl('   ');
      expect(container.read(userProvider)?.seerrCredentials?.localServerUrl, '');
    });
  });
}
