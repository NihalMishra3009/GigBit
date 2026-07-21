import 'dart:async';

import 'package:flutter/material.dart';

import 'device_notification_service.dart';
import 'notification_history.dart';

OverlayEntry? _activeTopNotice;
Timer? _activeTopNoticeTimer;

void showTopNotification(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 2),
}) {
  final parsedDeviceEvent =
      isError ? null : _parseDeviceNotificationEvent(message);

  unawaited(
    NotificationHistoryStore.add(
      message: message,
      isError: isError,
    ),
  );

  if (parsedDeviceEvent != null) {
    unawaited(
      DeviceNotificationService.show(
        id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
        title: parsedDeviceEvent.$1,
        body: parsedDeviceEvent.$2,
      ),
    );
    // For OS-notification events, do not show in-app top banner.
    _activeTopNoticeTimer?.cancel();
    _activeTopNotice?.remove();
    _activeTopNotice = null;
    return;
  }

  _activeTopNoticeTimer?.cancel();
  _activeTopNotice?.remove();
  _activeTopNotice = null;

  final overlay = Overlay.of(context, rootOverlay: true);

  final isDark = Theme.of(context).brightness == Brightness.dark;

  final entry = OverlayEntry(
    builder: (ctx) {
      final top = MediaQuery.of(ctx).padding.top + 10;
      final bg = isError
          ? (isDark ? const Color(0xFF3A1717) : const Color(0xFFFFE9E9))
          : (isDark ? const Color(0xFF13213D) : const Color(0xFFEAF1FF));
      final border = isError
          ? const Color(0xFFEF4444)
          : (isDark ? const Color(0xFF4A6DBA) : const Color(0xFF1E3A8A));
      final textColor = isError
          ? (isDark ? const Color(0xFFFFC5C5) : const Color(0xFF8E1F1F))
          : (isDark ? const Color(0xFFE8EEFF) : const Color(0xFF0F172A));

      return Positioned(
        left: 12,
        right: 12,
        top: top,
        child: _TopNoticeCard(
          background: bg,
          border: border,
          textColor: textColor,
          isDark: isDark,
          message: message,
        ),
      );
    },
  );

  overlay.insert(entry);
  _activeTopNotice = entry;
  _activeTopNoticeTimer = Timer(duration, () {
    if (_activeTopNotice == entry) {
      entry.remove();
      _activeTopNotice = null;
    }
  });
}

(String, String)? _parseDeviceNotificationEvent(String message) {
  final m = message.toLowerCase().trim();
  if (m.isEmpty) return null;

  if (m.contains('platform connected') || m.endsWith(' connected')) {
    return ('Platform Connected', message);
  }
  if (m.contains('platform disconnected') || m.contains(' disconnected')) {
    return ('Platform Disconnected', message);
  }
  if (m.contains('synced') || m.contains('all platforms synced')) {
    return ('Platform Sync', message);
  }
  if (m.contains('withdrawed successfully') ||
      m.contains('withdrawal successful')) {
    return ('Withdrawal', message);
  }
  if (m.contains('ticket submitted') || m.contains('raised a ticket')) {
    return ('Support Ticket', message);
  }
  if (m.contains('plan purchased') || m.contains('subscription updated')) {
    return ('Plan Purchased', message);
  }
  if (m.contains('payment method added')) {
    return ('Payment Method', message);
  }
  if (m.contains('pdf downloaded') || m.contains('pdf ready')) {
    return ('PDF Downloaded', message);
  }
  if (m.contains('insurance enabled')) {
    return ('Insurance', message);
  }
  if (m.contains('insurance claim applied')) {
    return ('Insurance Claim', message);
  }
  if (m.contains('loan applied')) {
    return ('Loan', message);
  }
  if (m.contains('password changed') || m.contains('password updated')) {
    return ('Password Changed', message);
  }
  if (m.contains('email changed') || m.contains('email updated')) {
    return ('Email Changed', message);
  }
  return null;
}

class _TopNoticeCard extends StatelessWidget {
  const _TopNoticeCard({
    required this.background,
    required this.border,
    required this.textColor,
    required this.isDark,
    required this.message,
  });

  final Color background;
  final Color border;
  final Color textColor;
  final bool isDark;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Text(
          message,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

