import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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

class _FakeUser extends User {
  _FakeUser(this.account);

  final AccountModel? account;

  @override
  AccountModel? build() => account;
}

/// Answers /api/v1/status only after [delay], so the Seerr probe stays in flight
/// long enough to observe what the Jellyfin barrier does.
Future<HttpServer> _slowSeerr(Duration delay) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await Future<void>.delayed(delay);
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"version":"3.5.1"}');
    await request.response.close();
  });
  return server;
}

/// Container whose account has [localUrl] configured, with account persistence
/// wired to [prefs] so credential setters work.
ProviderContainer _seerrContainer(String localUrl, SharedPreferences prefs) {
  final container = ProviderContainer(
    overrides: [
      userProvider.overrideWith(
        () => _FakeUser(
          AccountModel(
            name: 'tester',
            id: 'user-1',
            avatar: '',
            lastUsed: DateTime(2026, 1, 1),
            credentials: CredentialsModel.internal(token: 'token'),
            seerrCredentials: SeerrCredentialsModel(
              serverUrl: 'https://seerr.example.com',
              localServerUrl: localUrl,
              apiKey: 'key',
            ),
          ),
        ),
      ),
      sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The test binding installs a mock HttpClient that answers every request with
    // 400; the probe has to reach the loopback server for real.
    HttpOverrides.global = null;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), null);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'), null);
  });

  test('the Jellyfin barrier does not wait for the Seerr probe, the Seerr barrier does', () async {
    final server = await _slowSeerr(const Duration(milliseconds: 800));
    addTearDown(() => server.close(force: true));
    final localUrl = 'http://127.0.0.1:${server.port}';

    final container = ProviderContainer(
      overrides: [
        userProvider.overrideWith(
          () => _FakeUser(
            AccountModel(
              name: 'tester',
              id: 'user-1',
              avatar: '',
              lastUsed: DateTime(2026, 1, 1),
              // No Jellyfin URLs to probe, so the Jellyfin part settles immediately.
              credentials: CredentialsModel.internal(token: 'token'),
              seerrCredentials: SeerrCredentialsModel(serverUrl: 'https://seerr.example.com', localServerUrl: localUrl),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(connectivityStatusProvider.notifier);
    await notifier.checkConnectivity(immediate: true);

    var seerrProbeDone = false;
    unawaited(notifier.waitForSeerrProbe().then((_) => seerrProbeDone = true));

    await notifier.waitForProbe();
    expect(seerrProbeDone, isFalse, reason: 'Jellyfin requests must not wait for the Seerr probe');

    await notifier.waitForSeerrProbe();
    expect(seerrProbeDone, isTrue);
    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: true, rejected: false));
  });

  test('a superseded probe does not overwrite the current probe result', () async {
    // Probes that started while `slow` is set answer late with a 200; the probe that
    // supersedes them answers fast with a 404. Only the newest result may land.
    var slow = true;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final slowRequest = slow;
      if (slowRequest) await Future<void>.delayed(const Duration(milliseconds: 800));
      request.response.statusCode = slowRequest ? 200 : 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"version":"3.5.1"}');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final localUrl = 'http://127.0.0.1:${server.port}';

    final container = ProviderContainer(
      overrides: [
        userProvider.overrideWith(
          () => _FakeUser(
            AccountModel(
              name: 'tester',
              id: 'user-1',
              avatar: '',
              lastUsed: DateTime(2026, 1, 1),
              credentials: CredentialsModel.internal(token: 'token'),
              seerrCredentials: SeerrCredentialsModel(serverUrl: 'https://seerr.example.com', localServerUrl: localUrl),
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(connectivityStatusProvider.notifier);
    await notifier.checkConnectivity(immediate: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    slow = false;
    await notifier.checkConnectivity(immediate: true);

    await notifier.waitForSeerrProbe();
    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: false, rejected: false));

    // The superseded probes answer late; their results must be discarded.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: false, rejected: false));
    expect(container.read(seerrServerUrlProvider), 'https://seerr.example.com');
  });

  test('a rejection survives a probe that finds the same URL reachable', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final server = await _slowSeerr(Duration.zero);
    addTearDown(() => server.close(force: true));
    final localUrl = 'http://127.0.0.1:${server.port}';

    final container = _seerrContainer(localUrl, prefs);
    container.read(seerrLocalProbeProvider.notifier).state = (url: localUrl, reachable: true, rejected: true);

    final notifier = container.read(connectivityStatusProvider.notifier);
    await notifier.checkConnectivity(immediate: true);
    await notifier.waitForSeerrProbe();

    // Reachability cannot clear a rejection: the status endpoint keeps answering.
    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: true, rejected: true));
    expect(container.read(seerrServerUrlProvider), 'https://seerr.example.com');
  });

  test('editing the API key clears a rejection for the same URL', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final server = await _slowSeerr(Duration.zero);
    addTearDown(() => server.close(force: true));
    final localUrl = 'http://127.0.0.1:${server.port}';

    final container = _seerrContainer(localUrl, prefs);
    final notifier = container.read(connectivityStatusProvider.notifier);
    await notifier.checkConnectivity(immediate: true);
    await notifier.waitForSeerrProbe();
    container.read(seerrLocalProbeProvider.notifier).state = (url: localUrl, reachable: true, rejected: true);

    container.read(userProvider.notifier).setSeerrApiKey('new-key');
    await notifier.checkConnectivity(immediate: true);
    await notifier.waitForSeerrProbe();

    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: true, rejected: false));
    expect(container.read(seerrServerUrlProvider), localUrl);
  });

  test('editing the custom headers clears a rejection for the same URL', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final server = await _slowSeerr(Duration.zero);
    addTearDown(() => server.close(force: true));
    final localUrl = 'http://127.0.0.1:${server.port}';

    final container = _seerrContainer(localUrl, prefs);
    final notifier = container.read(connectivityStatusProvider.notifier);
    await notifier.checkConnectivity(immediate: true);
    await notifier.waitForSeerrProbe();
    container.read(seerrLocalProbeProvider.notifier).state = (url: localUrl, reachable: true, rejected: true);

    container.read(userProvider.notifier).setSeerrCustomHeaders({'Authorization': 'Bearer token'});
    await notifier.checkConnectivity(immediate: true);
    await notifier.waitForSeerrProbe();

    expect(container.read(seerrLocalProbeProvider), (url: localUrl, reachable: true, rejected: false));
    expect(container.read(seerrServerUrlProvider), localUrl);
  });
}
