import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class NotificationHistoryStore {
  static const _key = 'gigbit_notification_history_v1';
  static const _maxItems = 250;

  static bool _shouldStore({
    required String message,
    required bool isError,
  }) {
    final m = message.toLowerCase().trim();
    if (m.isEmpty) return false;

    // Do not store backend/API connectivity failures in notification history.
    if (m.contains('backend unreachable') ||
        m.contains('start api on') ||
        m.contains('check api on') ||
        m.contains('request timed out') ||
        m.contains('api error') ||
        m.contains('socketexception') ||
        m.contains('connection refused') ||
        m.contains('request failed')) {
      return false;
    }

    // For explicit errors, skip generic infrastructure failures.
    if (isError &&
        (m.contains('api') && m.contains('error') ||
            m.contains('backend') && m.contains('error'))) {
      return false;
    }

    return true;
  }

  static Future<void> add({
    required String message,
    required bool isError,
  }) async {
    final trimmed = message.trim();
    if (!_shouldStore(message: trimmed, isError: isError)) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = _decode(raw);

    list.insert(0, {
      'message': trimmed,
      'isError': isError,
      'tag': inferTag(trimmed, isError: isError),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });

    if (list.length > _maxItems) {
      list.removeRange(_maxItems, list.length);
    }

    await prefs.setString(_key, jsonEncode(list));
  }

  static Future<List<Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return _decode(raw);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<void> deleteAt(int index) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final list = _decode(raw);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    await prefs.setString(_key, jsonEncode(list));
  }

  static List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .map((e) {
        if ((e['tag'] ?? '').toString().trim().isEmpty) {
          final msg = (e['message'] ?? '').toString();
          final isError =
              e['isError'] == true || '${e['isError']}'.toLowerCase() == 'true';
          e['tag'] = inferTag(msg, isError: isError);
        }
        return e;
      }).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static String inferTag(
    String message, {
    bool isError = false,
  }) {
    final m = message.toLowerCase();
    if (isError) return 'Error';
    if (m.contains('transaction') || m.contains('expense')) {
      return 'Transaction';
    }
    if (m.contains('claim') || m.contains('insurance')) {
      return 'Claim';
    }
    if (m.contains('otp') || m.contains('password') || m.contains('login')) {
      return 'Auth';
    }
    if (m.contains('plan') ||
        m.contains('subscription') ||
        m.contains('payment')) {
      return 'Plan';
    }
    if (m.contains('sync') ||
        m.contains('connected') ||
        m.contains('connect') ||
        m.contains('platform')) {
      return 'Integration';
    }
    if (m.contains('profile') ||
        m.contains('settings') ||
        m.contains('feature') ||
        m.contains('benefit')) {
      return 'Settings';
    }
    if (m.contains('ticket') || m.contains('support') || m.contains('faq')) {
      return 'Support';
    }
    return 'General';
  }
}
