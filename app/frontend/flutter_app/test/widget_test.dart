import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:gigbit_flutter/app.dart';
import 'package:gigbit_flutter/core/app_strings.dart';

void main() {
  testWidgets('GigBit app renders auth shell', (WidgetTester tester) async {
    await tester.pumpWidget(
      const GigBitApp(
        initialToken: null,
        initialLanguage: AppLanguage.en,
        initialThemeMode: ThemeMode.dark,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GigBit'), findsWidgets);
  });
}
