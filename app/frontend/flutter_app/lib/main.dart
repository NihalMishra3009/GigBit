import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/app_strings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('auth_token');
  final langRaw = prefs.getString('app_language') ?? 'en';
  final themeRaw = prefs.getString('theme_mode') ?? ThemeMode.system.name;

  final language = AppLanguage.values.firstWhere(
    (e) => e.name == langRaw,
    orElse: () => AppLanguage.en,
  );
  final themeMode = ThemeMode.values.firstWhere(
    (e) => e.name == themeRaw,
    orElse: () => ThemeMode.system,
  );

  runApp(
    GigBitApp(
      initialToken: token,
      initialLanguage: language,
      initialThemeMode: themeMode,
    ),
  );
}
