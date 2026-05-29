import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_strings.dart';
import 'core/base_url.dart';
import 'core/backend_resolver.dart';
import 'core/device_notification_service.dart';
import 'features/auth/auth_screen.dart';
import 'features/dashboard/dashboard_screen.dart';

class GigBitApp extends StatefulWidget {
  const GigBitApp({
    super.key,
    required this.initialToken,
    required this.initialLanguage,
    required this.initialThemeMode,
  });

  final String? initialToken;
  final AppLanguage initialLanguage;
  final ThemeMode initialThemeMode;

  @override
  State<GigBitApp> createState() => _GigBitAppState();
}

class _GigBitAppState extends State<GigBitApp> {
  static const _kLang = 'app_language';
  static const _kThemeMode = 'theme_mode';

  late String? _token;
  late ThemeMode _themeMode;
  late AppLanguage _language;

  SystemUiOverlayStyle _overlayStyleForThemeMode(ThemeMode mode) {
    final isDarkMode = mode == ThemeMode.dark;
    return SystemUiOverlayStyle(
      statusBarColor:
          isDarkMode ? const Color(0xFF0B1020) : const Color(0xFFF8FAFC),
      statusBarIconBrightness:
          isDarkMode ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDarkMode ? Brightness.dark : Brightness.light,
      systemNavigationBarColor:
          isDarkMode ? const Color(0xFF0B1020) : const Color(0xFFF8FAFC),
      systemNavigationBarIconBrightness:
          isDarkMode ? Brightness.light : Brightness.dark,
      systemNavigationBarDividerColor:
          isDarkMode ? const Color(0xFF0B1020) : const Color(0xFFF8FAFC),
    );
  }

  @override
  void initState() {
    super.initState();
    _token = widget.initialToken;
    _language = widget.initialLanguage;
    _themeMode = widget.initialThemeMode;
    SystemChrome.setSystemUIOverlayStyle(_overlayStyleForThemeMode(_themeMode));
    DeviceNotificationService.init();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();

    // 1) Prefer build-time API base URL (scripts/run-android.cmd passes this).
    final defined = sanitizeApiBaseUrl(definedApiBaseUrl());
    if (defined != null) {
      await prefs.setString(kApiBaseUrlPrefKey, defined);
      setRuntimeApiBaseUrl(defined);
    } else {
      // 2) Load persisted base URL, but sanitize it.
      final persisted = prefs.getString(kApiBaseUrlPrefKey);
      final migrated = sanitizeApiBaseUrl(persisted);
      setRuntimeApiBaseUrl(migrated);
      if (migrated != null && migrated != persisted) {
        await prefs.setString(kApiBaseUrlPrefKey, migrated);
      }
    }

    // If we have a build-time API base URL, do not auto-switch away from it.
    // This prevents the app from falling back to 127.0.0.1/10.0.2.2 and getting stuck.
    if (defined == null) {
      // Probe candidates (health check) to auto-heal misconfiguration.
      final preferred = resolveApiBaseUrl();
      final resolved = await BackendResolver.resolve(preferred: preferred);

      // Always persist a sane value so the app never gets stuck on a bad URL.
      final finalBase = resolved ?? preferred;
      await prefs.setString(kApiBaseUrlPrefKey, finalBase);
      setRuntimeApiBaseUrl(finalBase);
    }

    final token = prefs.getString('auth_token');
    final langRaw = prefs.getString(_kLang) ?? 'en';
    final themeRaw = prefs.getString(_kThemeMode) ?? ThemeMode.dark.name;
    final lang = AppLanguage.values.firstWhere(
      (e) => e.name == langRaw,
      orElse: () => AppLanguage.en,
    );
    final theme = ThemeMode.values.firstWhere(
      (e) => e.name == themeRaw,
      orElse: () => ThemeMode.dark,
    );
    if (!mounted) return;
    final changed =
        _token != token || _language != lang || _themeMode != theme;
    SystemChrome.setSystemUIOverlayStyle(_overlayStyleForThemeMode(theme));
    if (changed) {
      setState(() {
        _token = token;
        _language = lang;
        _themeMode = theme;
      });
    }
  }

  Future<void> _handleAuth(
    String token, {
    required bool isNewRegistration,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final defined = definedApiBaseUrl();
    if (defined != null) {
      await prefs.setString(kApiBaseUrlPrefKey, defined);
      setRuntimeApiBaseUrl(defined);
    }

    await prefs.setString('auth_token', token);

    if (!mounted) return;
    setState(() {
      _token = token;
    });
  }

  void _toggleTheme() {
    final next =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    SystemChrome.setSystemUIOverlayStyle(_overlayStyleForThemeMode(next));
    setState(() => _themeMode = next);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_kThemeMode, next.name));
  }

  Future<void> _cycleLanguage() async {
    final next = AppStrings.next(_language);
    final prefs = await SharedPreferences.getInstance();
    final defined = definedApiBaseUrl();
    if (defined != null) {
      await prefs.setString(kApiBaseUrlPrefKey, defined);
      setRuntimeApiBaseUrl(defined);
    }
    await prefs.setString(_kLang, next.name);
    if (!mounted) return;
    setState(() => _language = next);
  }

  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    final defined = definedApiBaseUrl();
    if (defined != null) {
      await prefs.setString(kApiBaseUrlPrefKey, defined);
      setRuntimeApiBaseUrl(defined);
    }
    await prefs.remove('auth_token');
    if (!mounted) return;
    setState(() {
      _token = null;
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  ThemeData _lightTheme() {
    const primary = Color(0xFF1E3A8A);
    const accent = Color(0xFF16C784);
    const background = Color(0xFFF8FAFC);
    const onPrimaryText = Color(0xFF0F172A);
    const secondaryText = Color(0xFF475569);

    const scheme = ColorScheme.light(
      primary: primary,
      secondary: accent,
      surface: Color(0xFFFFFFFF),
      onSurface: onPrimaryText,
      onPrimary: Color(0xFFFFFFFF),
      onSecondary: Color(0xFF05291E),
      error: Color(0xFFEF4444),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: const TextTheme(
        headlineLarge:
            TextStyle(color: onPrimaryText, fontWeight: FontWeight.w900),
        headlineMedium:
            TextStyle(color: onPrimaryText, fontWeight: FontWeight.w800),
        titleLarge:
            TextStyle(color: onPrimaryText, fontWeight: FontWeight.w700),
        titleMedium:
            TextStyle(color: onPrimaryText, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(fontWeight: FontWeight.w500, color: onPrimaryText),
        bodyMedium: TextStyle(color: secondaryText),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x1F1E3A8A)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x1F1E3A8A)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF05281F),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFFFFFFFF),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0x261E3A8A)),
        ),
        titleTextStyle: const TextStyle(
          color: onPrimaryText,
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
        contentTextStyle: const TextStyle(
          color: secondaryText,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: const IconThemeData(color: primary),
    );
  }

  ThemeData _darkTheme() {
    const primary = Color(0xFF0A1F44);
    const accent = Color(0xFF16C784);

    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: const Color(0xFFAEC9FF),
      secondary: accent,
      surface: const Color(0xFF111A2E),
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0B1020),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF131D33),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF032218),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF111A2E),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0x33FFFFFF)),
        ),
        titleTextStyle: const TextStyle(
          color: Color(0xFFE8EEFF),
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
        contentTextStyle: TextStyle(
          color: const Color(0xFFE8EEFF).withValues(alpha: 0.78),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (_token == null) {
      home = AuthScreen(
        language: _language,
        onAuthenticated: _handleAuth,
        onToggleTheme: _toggleTheme,
        onCycleLanguage: _cycleLanguage,
        isDarkMode: _themeMode == ThemeMode.dark,
      );
    } else {
      home = DashboardScreen(
        language: _language,
        token: _token!,
        onLogout: _handleLogout,
        onToggleTheme: _toggleTheme,
        onCycleLanguage: _cycleLanguage,
        isDarkMode: _themeMode == ThemeMode.dark,
      );
    }

    final statusBarStyle = _overlayStyleForThemeMode(_themeMode);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GigBit',
      theme: _lightTheme(),
      darkTheme: _darkTheme(),
      themeMode: _themeMode,
      themeAnimationDuration: Duration.zero,
      themeAnimationCurve: Curves.linear,
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        value: statusBarStyle,
        child: home,
      ),
    );
  }
}
