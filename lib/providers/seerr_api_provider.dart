import 'dart:developer';
import 'dart:io';

import 'package:chopper/chopper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/seerr_server_url_provider.dart';
import 'package:fladder/providers/seerr_service_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/seerr/seerr_chopper_service.dart';
import 'package:fladder/seerr/seerr_json_converter.dart';
import 'package:fladder/util/seerr_http_client.dart'
    if (dart.library.html) 'package:fladder/util/seerr_http_client_web.dart';

part 'seerr_api_provider.g.dart';

@Riverpod(keepAlive: true)
class SeerrApi extends _$SeerrApi {
  @override
  SeerrService build() {
    ref.watch(userProvider.select((u) => u?.seerrCredentials));

    final httpClient = createSeerrHttpClient();
    final chopperClient = ChopperClient(
      client: httpClient,
      converter: const SeerrJsonConverter(),
      interceptors: [
        SeerrRequest(ref),
        SeerrResponse(ref),
        HttpLoggingInterceptor(level: Level.basic),
      ],
    );

    ref.onDispose(() {
      chopperClient.dispose();
      httpClient.close();
    });

    return SeerrService(
      ref,
      SeerrChopperService.create(chopperClient),
    );
  }
}

class SeerrRequest implements Interceptor {
  SeerrRequest(this.ref);

  final Ref ref;

  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(Chain<BodyType> chain) async {
    // Only a configured local URL needs the barrier; credentials and the effective
    // URL are read afterwards so an edit made while the request waits is honoured.
    if ((ref.read(userProvider)?.seerrCredentials?.localServerUrl.trim() ?? '').isNotEmpty) {
      await ref.read(connectivityStatusProvider.notifier).waitForSeerrProbe();
    }

    final creds = ref.read(userProvider)?.seerrCredentials;
    final serverUrl = ref.read(seerrServerUrlProvider);
    if (serverUrl.isEmpty) {
      throw const HttpException('Seerr server not configured');
    }

    final apiKey = creds?.apiKey.trim() ?? '';
    final cookie = creds?.sessionCookie.trim() ?? '';

    final authHeaders = _authHeaders(apiKey: apiKey, cookie: cookie);
    final customHeaders = {
      ...?creds?.customHeaders,
    };
    final headers = {...authHeaders, ...customHeaders};
    final apiBaseUri = Uri.parse(serverUrl);

    Uri resolvedRequestUri;
    try {
      resolvedRequestUri = apiBaseUri.resolveUri(chain.request.url);
    } catch (_) {
      resolvedRequestUri = chain.request.url;
    }

    final requestWithHeaders = applyHeaders(
      chain.request.copyWith(baseUri: apiBaseUri),
      headers,
    );

    try {
      final response = await chain.proceed(requestWithHeaders);
      final requestUrl = response.base.request?.url ?? chain.request.url;
      if (response.statusCode == 401 && !_isCredentialSubmission(requestUrl)) {
        // The instance answered but rejected our credentials. Probing cannot detect
        // this, so the rejection outranks a later reachable probe.
        _markLocalSeerr(ref, serverUrl, rejected: true);
      }
      // 403 means the request was authorized badly (quota, missing permission),
      // not that this instance is unusable, so it leaves the routing untouched.
      return response;
    } catch (e, st) {
      _markLocalSeerr(ref, serverUrl, rejected: false);
      throw HttpException(
        'Seerr API request failed: ${chain.request.method} $resolvedRequestUri\nError: $e\n$st',
      );
    }
  }
}

/// Endpoints that submit credentials instead of using them: a 401 here means the
/// typed password was wrong, not that this instance rejects the stored credentials.
bool _isCredentialSubmission(Uri url) =>
    url.path.endsWith('/auth/local') || url.path.endsWith('/auth/jellyfin');

/// Records that [usedBaseUrl] rejected the stored credentials ([rejected] true) or
/// stopped answering (false).
///
/// Does nothing unless [usedBaseUrl] is still the configured local URL, so a late
/// answer never judges a URL this request did not talk to.
void _markLocalSeerr(Ref ref, String usedBaseUrl, {required bool rejected}) {
  final localUrl = ref.read(userProvider)?.seerrCredentials?.localServerUrl.trim() ?? '';
  if (localUrl.isEmpty || usedBaseUrl != localUrl) return;
  final previous = ref.read(seerrLocalProbeProvider);
  ref.read(seerrLocalProbeProvider.notifier).state = (
    url: localUrl,
    // A 401 means the URL answered; a thrown request means it did not.
    reachable: rejected,
    // A recorded rejection outlives a later failure for the same URL.
    rejected: rejected || (previous.url == localUrl && previous.rejected),
  );
}

Map<String, String> _authHeaders({required String apiKey, required String cookie}) {
  if (apiKey.isNotEmpty) return {'X-Api-Key': apiKey};
  if (cookie.isNotEmpty && cookie != kBrowserManagedCookie) return {'Cookie': cookie};
  if (cookie == kBrowserManagedCookie) return const {};
  return const {};
}

class SeerrResponse implements Interceptor {
  SeerrResponse(this.ref);

  final Ref ref;

  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(Chain<BodyType> chain) async {
    final Response<BodyType> response = await chain.proceed(chain.request);

    if (!response.isSuccessful) {
      final method = response.base.request?.method;
      final url = response.base.request?.url.toString();
      final status = response.base.statusCode;
      final reason = response.base.reasonPhrase;

      final body = response.bodyString;
      final bodyPreview = body.length <= 1500 ? body : '${body.substring(0, 1500)}…';

      log(
        'x- $status - $reason - ${response.error} - $method $url\n$bodyPreview',
      );
    }

    return response;
  }
}
