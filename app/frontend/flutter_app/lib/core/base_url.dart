import 'package:flutter/foundation.dart';

const String _definedApiBaseUrl = String.fromEnvironment('API_BASE_URL');
const String _definedHostLanIp = String.fromEnvironment('HOST_LAN_IP');
const String _railwayProductionApiBase = 'https://gigbit-api-production.up.railway.app';

String? definedApiBaseUrl() {
  return _definedApiBaseUrl.isNotEmpty ? _definedApiBaseUrl : null;
}

String? definedHostLanIp() {
  return _definedHostLanIp.isNotEmpty ? _definedHostLanIp : null;
}

// SharedPreferences key (saved by the app in debug/dev scenarios).
const String kApiBaseUrlPrefKey = 'api_base_url';

String? _runtimeApiBaseUrl;

/// Normalizes + rejects persisted URLs that cause Android-to-host connectivity
/// issues.
String? sanitizeApiBaseUrl(String? url) {
  var v = (url ?? '').trim();
  if (v.isEmpty) return null;
  if (v.endsWith('/')) v = v.substring(0, v.length - 1);

  Uri uri;
  try {
    uri = Uri.parse(v);
  } catch (_) {
    return null;
  }

  if (!uri.hasScheme || uri.host.isEmpty) return null;

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final lan = definedHostLanIp();
    final allowedHosts = <String>{'127.0.0.1', 'localhost', '10.0.2.2'};
    if (lan != null && lan.isNotEmpty) allowedHosts.add(lan);

    // Allow common Wi-Fi LAN ranges so the app can keep working when opened from
    // the launcher (without --dart-define).
    final host = uri.host;
    final isCommonLan = RegExp(r'^(10\.|192\.168\.)').hasMatch(host);
    final isSecurePublicUrl = uri.scheme.toLowerCase() == 'https';

    if (!allowedHosts.contains(host) && !isCommonLan && !isSecurePublicUrl) {
      return null;
    }
  }

  return v;
}

void setRuntimeApiBaseUrl(String? url) {
  _runtimeApiBaseUrl = sanitizeApiBaseUrl(url);
}

String resolveApiBaseUrl() {
  if (_runtimeApiBaseUrl != null && _runtimeApiBaseUrl!.isNotEmpty) {
    return _runtimeApiBaseUrl!;
  }

  final defined = sanitizeApiBaseUrl(definedApiBaseUrl());
  if (defined != null) {
    return defined;
  }

  if (kIsWeb) {
    return 'http://localhost:4000';
  }

  // Default mobile fallback: always use production Railway API unless explicitly
  // overridden by runtime/build-time URL.
  return _railwayProductionApiBase;
}
