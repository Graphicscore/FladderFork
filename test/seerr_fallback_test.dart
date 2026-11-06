import 'dart:async';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/models/account_model.dart';
import 'package:fladder/models/credentials_model.dart';
import 'package:fladder/models/seerr_credentials_model.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/seerr_api_provider.dart';
import 'package:fladder/providers/seerr_server_url_provider.dart';
import 'package:fladder/providers/shared_provider.dart';
import 'package:fladder/providers/user_provider.dart';

const _localUrl = 'http://192.168.1.10:5055';
const _remoteUrl = 'https://seerr.example.com';

class _FakeUser extends User {
  _FakeUser(this.account);

  final AccountModel? account;

  @override
  AccountModel? build() => account;
}

class _FakeConnectivity extends ConnectivityStatus {
  /// When set, `waitForSeerrProbe()` blocks until it completes.
  Completer<void>? barrier;

  @override
  ConnectionState build() => ConnectionState.wifi;

  @override
  Future<void> waitForSeerrProbe() async {
    final pending = barrier;
    if (pending != null) await pending.future;
  }
}

/// Runs [SeerrRequest] against a chain that answers with [statusCode] or throws.
class _FakeChain implements Chain<String> {
  _FakeChain(this.request, {required this.statusCode, this.throwOnProceed = false, this.onProceed});

  @override
  final Request request;

  final int statusCode;
  final bool throwOnProceed;
  final void Function()? onProceed;

  /// The request the interceptor actually sent.
  Request? sent;

  @override
  FutureOr<Response<String>> proceed(Request request) {
    sent = request;
    onProceed?.call();
    if (throwOnProceed) throw const SocketException('connection refused');
    return Response<String>(http.Response('', statusCode), null);
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      userProvider.overrideWith(
        () => _FakeUser(
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
            seerrCredentials: const SeerrCredentialsModel(
              serverUrl: _remoteUrl,
              localServerUrl: _localUrl,
              apiKey: 'key',
            ),
          ),
        ),
      ),
      connectivityStatusProvider.overrideWith(_FakeConnectivity.new),
      sharedUtilityProvider.overrideWith((ref) => SharedUtility(ref: ref, sharedPreferences: prefs)),
      seerrLocalProbeProvider.overrideWith((ref) => (url: _localUrl, reachable: true, rejected: false)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<Response<String>> _sendTyped(
  ProviderContainer container, {
  required String path,
  int statusCode = 200,
  bool throwOnProceed = false,
  void Function()? onProceed,
}) {
  final request = Request('GET', Uri.parse(path), Uri.parse('http://127.0.0.1:1'));
  final chain = _FakeChain(
    request,
    statusCode: statusCode,
    throwOnProceed: throwOnProceed,
    onProceed: onProceed,
  );
  return Future.value(SeerrRequest(container.read(_refProvider)).intercept(chain));
}

void main() {
  test('sends the request to the local URL while the probe allows it', () async {
    final container = await _container();
    final request = Request('GET', Uri.parse('/api/v1/status'), Uri.parse('http://127.0.0.1:1'));
    final chain = _FakeChain(request, statusCode: 200);

    await SeerrRequest(container.read(_refProvider)).intercept(chain);

    expect(container.read(seerrServerUrlProvider), _localUrl);
    expect(chain.sent?.baseUri, Uri.parse(_localUrl));
  });

  test('sends the request to the configured URL when the probe does not allow local', () async {
    final container = await _container();
    container.read(seerrLocalProbeProvider.notifier).state = (url: _localUrl, reachable: false, rejected: false);
    final request = Request('GET', Uri.parse('/api/v1/status'), Uri.parse('http://127.0.0.1:1'));
    final chain = _FakeChain(request, statusCode: 200);

    await SeerrRequest(container.read(_refProvider)).intercept(chain);

    expect(chain.sent?.baseUri, Uri.parse(_remoteUrl));
  });

  test('waits for the Seerr probe before sending the request', () async {
    final container = await _container();
    final connectivity = container.read(connectivityStatusProvider.notifier) as _FakeConnectivity;
    connectivity.barrier = Completer<void>();

    var proceeded = false;
    final pending = _sendTyped(container, path: '/api/v1/status', onProceed: () => proceeded = true);
    await Future<void>.delayed(Duration.zero);
    expect(proceeded, isFalse, reason: 'the request must not be sent before the probe settles');

    connectivity.barrier!.complete();
    await pending;
    expect(proceeded, isTrue);
  });

  test('a 401 from a data endpoint rejects the local URL', () async {
    final container = await _container();

    await _sendTyped(container, path: '/api/v1/request', statusCode: 401);

    expect(container.read(seerrLocalProbeProvider), (url: _localUrl, reachable: true, rejected: true));
    expect(container.read(seerrServerUrlProvider), _remoteUrl);
  });

  test('a 401 from either login endpoint leaves the local URL alone', () async {
    for (final path in ['/api/v1/auth/local', '/api/v1/auth/jellyfin']) {
      final container = await _container();

      await _sendTyped(container, path: path, statusCode: 401);

      expect(container.read(seerrLocalProbeProvider).rejected, isFalse, reason: path);
      expect(container.read(seerrServerUrlProvider), _localUrl, reason: path);
    }
  });

  test('a 403 leaves the local URL alone', () async {
    final container = await _container();

    await _sendTyped(container, path: '/api/v1/request', statusCode: 403);

    expect(container.read(seerrLocalProbeProvider).rejected, isFalse);
    expect(container.read(seerrServerUrlProvider), _localUrl);
  });

  test('a connection failure marks the local URL unreachable but not rejected', () async {
    final container = await _container();

    await expectLater(
      _sendTyped(container, path: '/api/v1/request', throwOnProceed: true),
      throwsA(isA<HttpException>()),
    );

    expect(container.read(seerrLocalProbeProvider).reachable, isFalse);
    expect(container.read(seerrLocalProbeProvider).rejected, isFalse);
    expect(container.read(seerrServerUrlProvider), _remoteUrl);
  });

  test('a late 401 does not blame a local URL the request was not sent to', () async {
    final container = await _container();
    const newLocalUrl = 'http://192.168.1.20:5055';

    await _sendTyped(container, path: '/api/v1/request', statusCode: 401, onProceed: () {
      // The user edits the local URL while this request is in flight.
      container.read(userProvider.notifier).setSeerrLocalServerUrl(newLocalUrl);
    });

    expect(container.read(userProvider)?.seerrCredentials?.localServerUrl, newLocalUrl);
    expect(container.read(seerrLocalProbeProvider), (url: _localUrl, reachable: true, rejected: false));
  });

  test('a late connection failure does not judge a local URL the request was not sent to', () async {
    final container = await _container();
    const newLocalUrl = 'http://192.168.1.20:5055';

    await expectLater(
      _sendTyped(container, path: '/api/v1/request', throwOnProceed: true, onProceed: () {
        container.read(userProvider.notifier).setSeerrLocalServerUrl(newLocalUrl);
      }),
      throwsA(isA<HttpException>()),
    );

    expect(container.read(seerrLocalProbeProvider), (url: _localUrl, reachable: true, rejected: false));
  });
}
