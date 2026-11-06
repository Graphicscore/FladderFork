import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/providers/api_provider.dart';

/// Serves one canned response for every request and records the paths it saw.
class _FakeSeerr {
  _FakeSeerr._(this._server);

  final HttpServer _server;
  final List<String> paths = [];

  static Future<_FakeSeerr> start({
    required int statusCode,
    required String body,
    required String contentType,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeSeerr._(server);
    server.listen((request) async {
      fake.paths.add(request.uri.path);
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.write(body);
      await request.response.close();
    });
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

typedef _Negative = ({String name, int statusCode, String body, String contentType});

void main() {
  test('accepts a 2xx Seerr status payload from /api/v1/status', () async {
    final seerr = await _FakeSeerr.start(
      statusCode: 200,
      body: '{"version":"3.5.1","commitTag":"local","updateAvailable":false}',
      contentType: 'application/json',
    );
    addTearDown(seerr.close);

    expect(await fetchSeerrStatusDynamic(seerr.baseUrl), isTrue);
    expect(seerr.paths, ['/api/v1/status']);
  });

  test('keeps a base path in front of the status endpoint', () async {
    final seerr = await _FakeSeerr.start(
      statusCode: 200,
      body: '{"version":"3.5.1"}',
      contentType: 'application/json',
    );
    addTearDown(seerr.close);

    expect(await fetchSeerrStatusDynamic('${seerr.baseUrl}/seerr'), isTrue);
    expect(seerr.paths, ['/seerr/api/v1/status']);
  });

  const negatives = <_Negative>[
    (name: 'a 200 HTML captive portal page', statusCode: 200, body: '<html>Sign in</html>', contentType: 'text/html'),
    (name: 'a 200 JSON body without a version', statusCode: 200, body: '{"status":"ok"}', contentType: 'application/json'),
    (name: 'an empty version string', statusCode: 200, body: '{"version":""}', contentType: 'application/json'),
    (name: 'a non-string version', statusCode: 200, body: '{"version":123}', contentType: 'application/json'),
    (name: 'a JSON body that is not an object', statusCode: 200, body: '[]', contentType: 'application/json'),
    (name: 'a 404 response', statusCode: 404, body: '{"version":"3.5.1"}', contentType: 'application/json'),
  ];

  for (final negative in negatives) {
    test('rejects ${negative.name}', () async {
      final seerr = await _FakeSeerr.start(
        statusCode: negative.statusCode,
        body: negative.body,
        contentType: negative.contentType,
      );
      addTearDown(seerr.close);

      expect(await fetchSeerrStatusDynamic(seerr.baseUrl), isFalse);
    });
  }

  test('rejects a closed port', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${server.port}';
    await server.close(force: true);

    expect(await fetchSeerrStatusDynamic(url), isFalse);
  });

  test('rejects an empty URL', () async {
    expect(await fetchSeerrStatusDynamic(''), isFalse);
  });
}
