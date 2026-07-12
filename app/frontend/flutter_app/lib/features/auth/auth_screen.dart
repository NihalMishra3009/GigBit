import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/app_strings.dart';
import '../../core/base_url.dart';
import '../../core/overlay_animations.dart';
import '../../core/top_notification.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.language,
    required this.onAuthenticated,
    required this.onToggleTheme,
    required this.onCycleLanguage,
    required this.isDarkMode,
  });

  final AppLanguage language;
  final void Function(String token, {required bool isNewRegistration})
      onAuthenticated;
  final VoidCallback onToggleTheme;
  final VoidCallback onCycleLanguage;
  final bool isDarkMode;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _registerOtpController = TextEditingController();
  final _dailyFuelController = TextEditingController();
  final _rentController = TextEditingController();

  bool _isRegister = false;
  bool _loading = false;
  String? _error;

  bool _registerOtpSent = false;
  bool _registerOtpVerified = false;
  String? _registerOtpValue;

  bool _termsAccepted = false;
  bool _vehicleRented = false;
  bool _gigbitInsurance = false;
  bool _authPasswordVisible = false;

  String get _baseUrl => resolveApiBaseUrl();
  String t(String key) => AppStrings.t(widget.language, key);

  String _termsAndConditionsText() {
    return [
      'GigBit Terms & Conditions',
      '',
      '1. Platform Scope',
      'GigBit helps gig workers track earnings, expenses, insurance status, and tax assistance across integrated platforms.',
      '',
      '2. Account Responsibility',
      'You are responsible for your login credentials, OTP usage, and all actions performed through your account.',
      '',
      '3. Platform Integration',
      'Integrations are user-authorized. GigBit may show synced or estimated data based on available platform linkage.',
      '',
      '4. Subscription & Plan Limits',
      'Plan purchase determines the maximum number of platforms you can connect. Plan validity and limits are applied as shown in-app.',
      '',
      '5. Earnings, Trips, and Tax Data',
      'GigBit provides productivity and tax-support summaries for convenience. Final filing values must be reviewed by the user before submitting ITR.',
      '',
      '6. Insurance and Benefits',
      'Insurance-related benefits are available only when opted in. Applicable charges are shown in-app and may be auto-deducted as defined.',
      '',
      '7. Prohibited Usage',
      'Any fraudulent use, unauthorized access, abuse of OTP systems, or manipulation of records can lead to account suspension.',
      '',
      '8. Limitation',
      'GigBit does not provide legal or CA representation. Users should consult qualified professionals for legal and tax advice.',
    ].join('\n');
  }

  void _openTermsSheet() {
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        return SizedBox(
          height: h * 0.72,
          child: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                Text(
                  t('terms_conditions'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.07),
                        blurRadius: 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: SelectableText(
                    _termsAndConditionsText(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.82),
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmInsuranceOptIn() async {
    final ok = await showAnimatedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('insurance_opt_in_title')),
        content: Text(t('insurance_opt_in_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('no')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('yes')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _resetRegisterFlow() {
    _registerOtpSent = false;
    _registerOtpVerified = false;
    _registerOtpValue = null;
    _registerOtpController.clear();

    _termsAccepted = false;
    _vehicleRented = false;
    _gigbitInsurance = false;
    _dailyFuelController.clear();
    _rentController.clear();

    _usernameController.clear();
    _nameController.clear();
    _passwordController.clear();
  }

    Widget _togglePill({
    required bool value,
    required String label,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = value
        ? const Color(0xFF16C784)
        : (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : const Color(0x261E3A8A));

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border, width: value ? 1.6 : 1.0),
            color: value
                ? const Color(0xFF16C784).withValues(alpha: isDark ? 0.12 : 0.10)
                : Colors.transparent,
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isValidEmail(String email) {
    final e = email.trim();
    final re = RegExp(r'^([^@\s]+)@([^@\s]+)\.([^@\s]+)$');
    return re.hasMatch(e);
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ApiClient(baseUrl: _baseUrl);
      api.warmup();

      if (!_isRegister) {
        final response = await api.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        final token = response['token'] as String;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', token);
        widget.onAuthenticated(token, isNewRegistration: false);
        return;
      }

      if (!_registerOtpSent) {
        final email = _emailController.text.trim();
        if (!_isValidEmail(email)) {
          if (!mounted) return;
          showTopNotification(context, t('enter_valid_email'), isError: true);
          setState(() => _error = t('enter_valid_email'));
          return;
        }
        if (!_termsAccepted) {
          setState(() => _error = t('accept_terms_required'));
          return;
        }
        final response = await api.requestRegisterOtp(email: _emailController.text.trim());
        final otpValue = response['otp'] as String?;
        if (!mounted) return;
        setState(() {
          _registerOtpSent = true;
          _registerOtpValue = otpValue;
        });
        showTopNotification(
          context,
          otpValue != null
              ? "${t('otp_sent_to_email')} OTP: $otpValue"
              : t('otp_sent_to_email'),
        );
        return;
      }

      if (!_registerOtpVerified) {
        await api.verifyRegisterOtp(
          email: _emailController.text.trim(),
          otp: _registerOtpController.text.trim(),
        );
        if (!mounted) return;
        setState(() {
          _registerOtpVerified = true;
          _registerOtpController.clear();
        });
        showTopNotification(context, t('otp_verified_continue'));
        return;
      }

      final fullName = _nameController.text.trim();
      final username = _usernameController.text.trim().toLowerCase();
      final password = _passwordController.text;
      final usernameOk = RegExp(r'^[a-z0-9._]{3,24}$').hasMatch(username);

      if (fullName.length < 2) {
        setState(() => _error = t('enter_full_name'));
        return;
      }
      if (!usernameOk) {
        setState(() => _error = t('enter_valid_username'));
        return;
      }
      if (password.length < 8) {
        setState(() => _error = t('new_password_min_8'));
        return;
      }

      final dailyFuelText = _dailyFuelController.text.trim();
      final dailyFuel = double.tryParse(dailyFuelText);
      if (dailyFuel == null || !(dailyFuel > 0)) {
        setState(() => _error = t('enter_daily_fuel'));
        return;
      }
      if (_vehicleRented) {
        final rentText = _rentController.text.trim();
        final rent = double.tryParse(rentText);
        if (rent == null || !(rent > 0)) {
          setState(() => _error = t('enter_valid_rent'));
          return;
        }
      }

      final response = await api.completeRegistration(
        email: _emailController.text.trim(),
        fullName: fullName,
        username: username,
        password: password,
        vehicleRented: _vehicleRented,
        gigbitInsurance: _gigbitInsurance,
        dailyFuel: dailyFuel,
        rent: _vehicleRented ? double.tryParse(_rentController.text.trim()) : null,
      );

      final token = response['token'] as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_token', token);
      widget.onAuthenticated(token, isNewRegistration: true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPasswordFlow() async {
    final emailController =
        TextEditingController(text: _emailController.text.trim());
    final otpController = TextEditingController();
    final newPasswordController = TextEditingController();

    final step1 = await showAnimatedDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('reset_password')),
        content: TextField(
          controller: emailController,
          decoration: InputDecoration(labelText: t('registered_email')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('send_otp')),
          ),
        ],
      ),
    );

    if (step1 != true) return;

    if (!emailController.text.trim().contains('@')) {
      if (!mounted) return;
      showTopNotification(context, t('enter_valid_email'), isError: true);
      return;
    }

    try {
      final api = ApiClient(baseUrl: _baseUrl);
      api.warmup();
      await api.requestPasswordReset(email: emailController.text.trim());
      if (!mounted) return;
      showTopNotification(context, t('otp_sent_to_email'));

      final step2 = await showAnimatedDialog<bool>(
        context: context,
        builder: (context) {
          bool resetPasswordVisible = false;
          return StatefulBuilder(
            builder: (context, setLocalState) => AlertDialog(
              title: Text(t('enter_otp')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: otpController,
                    decoration: InputDecoration(labelText: t('enter_otp')),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: newPasswordController,
                    obscureText: !resetPasswordVisible,
                    decoration: InputDecoration(
                      labelText: t('new_password'),
                      suffixIcon: IconButton(
                        onPressed: () => setLocalState(() {
                          resetPasswordVisible = !resetPasswordVisible;
                        }),
                        icon: Icon(
                          resetPasswordVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(t('update')),
                ),
              ],
            ),
          );
        },
      );

      if (step2 != true) return;

      final otp = otpController.text.trim();
      final newPassword = newPasswordController.text;
      if (otp.length != 6) {
        if (!mounted) return;
        showTopNotification(context, t('otp_must_be_6_digits'), isError: true);
        return;
      }
      if (newPassword.length < 8) {
        if (!mounted) return;
        showTopNotification(context, t('new_password_min_8'), isError: true);
        return;
      }

      await api.verifyPasswordReset(
        email: emailController.text.trim(),
        otp: otp,
        newPassword: newPassword,
      );
      if (!mounted) return;
      showTopNotification(context, t('password_updated'));
    } catch (e) {
      if (!mounted) return;
      showTopNotification(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    }
  }

  Widget _authCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : const Color(0x141E3A8A),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.08),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'GigBit',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: isDark ? const Color(0xFFE7EEFF) : const Color(0xFF000000),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isRegister ? t('create_your_account') : t('welcome_back'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? const Color(0xFFB6C2DD) : const Color(0xFF475569),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _emailController,
            enabled: !_registerOtpVerified,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          if (_isRegister && !_registerOtpSent) ...[
            const SizedBox(height: 6),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _termsAccepted = !_termsAccepted),
              child: Row(
                children: [
                  Checkbox(
                    value: _termsAccepted,
                    onChanged: (v) =>
                        setState(() => _termsAccepted = v ?? false),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        children: [
                          TextSpan(
                            text: t('accept_terms'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w800,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = _openTermsSheet,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_isRegister && _registerOtpSent && !_registerOtpVerified) ...[
            TextField(
              key: const ValueKey('register_otp'),
              controller: _registerOtpController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: InputDecoration(labelText: t('enter_otp')),
            ),
            if (_registerOtpValue != null) ...[
              const SizedBox(height: 8),
              Text(
                '${t('debug_otp_notice')} ${_registerOtpValue!}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          if (_isRegister && _registerOtpVerified) ...[
            TextField(
              key: const ValueKey('register_full_name'),
              controller: _nameController,
              keyboardType: TextInputType.name,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [
                // Allow names like "Hemant Thakur", "O'Neil", "A-B", "A. B."
                FilteringTextInputFormatter.allow(RegExp(r"[a-zA-Z\s\.\-']")),
                LengthLimitingTextInputFormatter(40),
              ],
              decoration: InputDecoration(labelText: t('full_name')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9._]')),
                LengthLimitingTextInputFormatter(24),
              ],
              decoration: InputDecoration(
                labelText: t('username'),
                hintText: 'thakur_01',
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (!_isRegister || _registerOtpVerified)
            TextField(
              controller: _passwordController,
              obscureText: !_authPasswordVisible,
              decoration: InputDecoration(
                labelText: t('password'),
                suffixIcon: IconButton(
                  onPressed: () => setState(() {
                    _authPasswordVisible = !_authPasswordVisible;
                  }),
                  icon: Icon(
                    _authPasswordVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
          if (_isRegister && _registerOtpVerified) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _togglePill(
                    value: _gigbitInsurance,
                    label: t('gigbit_insurance'),
                    onTap: () async {
                      if (_gigbitInsurance) {
                        setState(() => _gigbitInsurance = false);
                        return;
                      }
                      final ok = await _confirmInsuranceOptIn();
                      if (!mounted || !ok) return;
                      setState(() => _gigbitInsurance = true);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _togglePill(
                    value: _vehicleRented,
                    label: t('vehicle_rented'),
                    onTap: () =>
                        setState(() => _vehicleRented = !_vehicleRented),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dailyFuelController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(labelText: '${t('daily_fuel')} *'),
                  ),
                ),
                if (_vehicleRented) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _rentController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: InputDecoration(labelText: t('rent')),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (!_isRegister || _registerOtpVerified) const SizedBox(height: 14),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13),
              ),
            ),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              child: Text(
                _loading
                    ? t('please_wait')
                    : _isRegister
                        ? (_registerOtpVerified
                            ? t('create_account')
                            : (_registerOtpSent
                                ? t('verify_otp')
                                : t('send_otp')))
                        : t('login'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (!_isRegister)
            TextButton(
              onPressed: _forgotPasswordFlow,
              child: Text(t('forgot_password')),
            ),
          TextButton(
            onPressed: _loading
                ? null
                : () => setState(() {
                      _isRegister = !_isRegister;
                      _error = null;
                      _resetRegisterFlow();
                    }),
            child: Text(_isRegister ? t('already_account') : t('need_account')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0xFF0B1020),
                    Color(0xFF0A1F44),
                    Color(0xFF0E1A33),
                  ]
                : const [
                    Color(0xFFF8FAFC),
                    Color(0xFFF2F6FB),
                    Color(0xFFEAF1FA),
                  ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: widget.onCycleLanguage,
                          child: Text(AppStrings.label(widget.language)),
                        ),
                        IconButton(
                          onPressed: widget.onToggleTheme,
                          icon: Icon(
                            widget.isDarkMode
                                ? Icons.wb_sunny
                                : Icons.brightness_2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _authCard(isDark),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
