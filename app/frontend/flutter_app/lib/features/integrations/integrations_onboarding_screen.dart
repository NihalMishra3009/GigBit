import 'dart:math';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/app_strings.dart';
import '../../core/base_url.dart';
import '../../core/overlay_animations.dart';
import '../../core/top_notification.dart';

class IntegrationsOnboardingScreen extends StatefulWidget {
  const IntegrationsOnboardingScreen({
    super.key,
    required this.language,
    required this.token,
    required this.onCompleted,
    required this.onLogout,
    required this.onToggleTheme,
    required this.onCycleLanguage,
    required this.isDarkMode,
  });

  final AppLanguage language;
  final String token;
  final VoidCallback onCompleted;
  final VoidCallback onLogout;
  final VoidCallback onToggleTheme;
  final VoidCallback onCycleLanguage;
  final bool isDarkMode;

  @override
  State<IntegrationsOnboardingScreen> createState() =>
      _IntegrationsOnboardingScreenState();
}

class _PlatformState {
  _PlatformState({
    required this.name,
    String? displayName,
    required this.assetPath,
    required this.logoBackground,
    required this.brand,
  }) : displayName = displayName ?? name;

  final String name;
  String displayName;
  final String assetPath;
  String? logoUrl;
  Color logoBackground;
  final Color brand;
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController otpController = TextEditingController();
  String? mockOtp;
  bool otpSent = false;
  bool verified = false;
  bool isAvailable = true;
}

class _IntegrationsOnboardingScreenState
    extends State<IntegrationsOnboardingScreen> {
  static const Duration _kCatalogRefreshInterval = Duration(seconds: 8);
  static const Map<String, String> _defaultPlatformAssets = {
    'zomato': 'assets/platforms/zomato.png',
    'blinkit': 'assets/platforms/blinkit.png',
    'rapido': 'assets/platforms/rapido.png',
    'ola': 'assets/platforms/ola.png',
  };

  static const Map<String, Color> _defaultPlatformBrands = {
    'zomato': Color(0xFF000000),
    'blinkit': Color(0xFF555555),
    'rapido': Color(0xFF888888),
    'ola': Color(0xFFCCCCCC),
  };

  final _platforms = [
    _PlatformState(
      name: 'zomato',
      assetPath: 'assets/platforms/zomato.png',
      logoBackground: const Color(0xFF000000),
      brand: const Color(0xFF000000),
    ),
    _PlatformState(
      name: 'blinkit',
      assetPath: 'assets/platforms/blinkit.png',
      logoBackground: const Color(0xFF555555),
      brand: const Color(0xFF555555),
    ),
    _PlatformState(
      name: 'rapido',
      assetPath: 'assets/platforms/rapido.png',
      logoBackground: Colors.white,
      brand: const Color(0xFF888888),
    ),
    _PlatformState(
      name: 'ola',
      assetPath: 'assets/platforms/ola.png',
      logoBackground: Colors.white,
      brand: const Color(0xFFCCCCCC),
    ),
  ];

  String? _error;
  StreamSubscription<void>? _catalogEventsSub;
  Timer? _catalogPollTimer;
  String _lastCatalogSignature = '';

  String? _activePlan;
  bool _loadingPlan = false;

  ApiClient get _api =>
      ApiClient(baseUrl: resolveApiBaseUrl(), token: widget.token);
  String t(String key) => AppStrings.t(widget.language, key);

  Color _parseColorOrFallback(String? value, Color fallback) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return fallback;
    final hex = raw.replaceFirst('#', '');
    if (hex.length != 6 && hex.length != 8) return fallback;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return fallback;
    return Color(hex.length == 6 ? (0xFF000000 | parsed) : parsed);
  }

  String _catalogSignature(
    List<dynamic> catalog,
    Set<String> connectedSlugs,
    String activePlan,
  ) {
    final rows = <String>[];
    for (final raw in catalog) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final slug = (item['slug'] ?? '').toString().trim().toLowerCase();
      if (slug.isEmpty) continue;
      rows.add([
        slug,
        (item['name'] ?? '').toString().trim(),
        (item['logo_url'] ?? '').toString().trim(),
        (item['logo_bg_color'] ?? '').toString().trim(),
        ((item['enabled'] ?? true) == true) ? '1' : '0',
      ].join('|'));
    }
    rows.sort();
    final conn = connectedSlugs.toList()..sort();
    return '${activePlan.trim().toLowerCase()}::${rows.join('||')}::${conn.join(',')}';
  }

  Widget _logoFromUrl(
    String logoUrl, {
    required BoxFit fit,
    required Alignment alignment,
    required Color fallbackColor,
    double size = 24,
  }) {
    final lower = logoUrl.toLowerCase();
    if (lower.startsWith('data:image/')) {
      try {
        final comma = logoUrl.indexOf(',');
        if (comma > 0) {
          final meta = lower.substring(0, comma);
          final payload = logoUrl.substring(comma + 1);
          if (meta.contains('image/svg+xml')) {
            final svgRaw = meta.contains(';base64')
                ? utf8.decode(base64Decode(payload))
                : Uri.decodeComponent(payload);
            return SvgPicture.string(
              svgRaw,
              fit: fit,
              alignment: alignment,
            );
          }
          final Uint8List bytes = meta.contains(';base64')
              ? base64Decode(payload)
              : Uint8List.fromList(Uri.decodeComponent(payload).codeUnits);
          return Image.memory(
            bytes,
            fit: fit,
            alignment: alignment,
            filterQuality: FilterQuality.high,
            errorBuilder: (context, error, stackTrace) => Icon(
              Icons.link,
              color: fallbackColor,
              size: size,
            ),
          );
        }
      } catch (_) {
        // ignore malformed data URL and fallback below
      }
    }

    if (lower.endsWith('.svg')) {
      return SvgPicture.network(
        logoUrl,
        fit: fit,
        alignment: alignment,
      );
    }
    return Image.network(
      logoUrl,
      fit: fit,
      alignment: alignment,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.link,
        color: fallbackColor,
        size: size,
      ),
    );
  }

  String _plansHeaderLabel() {
    final plan = (_activePlan ?? '').trim().toLowerCase();
    if (plan == 'solo' || plan == 'duo' || plan == 'trio' || plan == 'unity') return t(plan);
    return t('plans');
  }

  Future<void> _loadActivePlan() async {
    if (_loadingPlan) return;
    _loadingPlan = true;
    try {
      final me = await _api.fetchMe();
      final sub = await _api.fetchSubscription(me['id'].toString());
      final catalog = await _api.fetchPlatformCatalog();
      final connectedPlatforms = await _api.fetchUserPlatforms();
      final active = (sub['activePlan'] ?? '').toString().trim();
      if (!mounted) return;
      final connectedSlugs = connectedPlatforms
          .map((e) => e.toString().trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet();
      final nextSignature = _catalogSignature(catalog, connectedSlugs, active);
      if (_lastCatalogSignature == nextSignature) {
        return;
      }
      setState(() {
        _lastCatalogSignature = nextSignature;
        _activePlan = active;
        final bySlug = <String, _PlatformState>{
          for (final p in _platforms) p.name.toLowerCase(): p,
        };
        for (final p in _platforms) {
          p.isAvailable = false;
        }
        for (final raw in catalog) {
          if (raw is! Map) continue;
          final item = Map<String, dynamic>.from(raw);
          final slug = (item['slug'] ?? '').toString().trim().toLowerCase();
          if (slug.isEmpty) continue;
          final fallbackBrand =
              _defaultPlatformBrands[slug] ?? const Color(0xFF1E3A8A);
          final bg = _parseColorOrFallback(
              item['logo_bg_color']?.toString(), fallbackBrand);
          final existing = bySlug[slug];
          final next = existing ??
              _PlatformState(
                name: slug,
                assetPath: _defaultPlatformAssets[slug] ?? '',
                logoBackground: bg,
                brand: fallbackBrand,
              );
          next.displayName = (item['name'] ?? slug).toString();
          next.logoUrl = (item['logo_url'] ?? '').toString().trim().isEmpty
              ? null
              : (item['logo_url'] ?? '').toString().trim();
          next.logoBackground = bg;
          next.isAvailable = true;
          next.verified = connectedSlugs.contains(slug);
          bySlug[slug] = next;
        }
        _platforms
          ..clear()
          ..addAll(
            bySlug.values.where((p) => p.isAvailable).toList()
              ..sort((a, b) => a.displayName
                  .toLowerCase()
                  .compareTo(b.displayName.toLowerCase())),
          );
        for (final p in _platforms) {
          p.verified = connectedSlugs.contains(p.name.toLowerCase());
        }
      });
    } catch (_) {
      // ignore
    } finally {
      _loadingPlan = false;
    }
  }

  @override
  void dispose() {
    _catalogEventsSub?.cancel();
    _catalogPollTimer?.cancel();
    for (final p in _platforms) {
      p.phoneController.dispose();
      p.otpController.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadActivePlan();
    _catalogEventsSub = _api.platformCatalogEvents().listen((_) {
      if (!mounted) return;
      _loadActivePlan();
    });
    _catalogPollTimer = Timer.periodic(_kCatalogRefreshInterval, (_) {
      if (!mounted) return;
      _loadActivePlan();
    });
  }

  int _randomOtp() => 100000 + Random().nextInt(900000);

  int _planPrice(String plan) {
    switch (plan) {
      case 'solo':
        return 25;
      case 'duo':
        return 50;
      case 'trio':
        return 75;
      case 'unity':
        return 229;
      default:
        return 0;
    }
  }

  int _planLimit(String plan) {
    switch (plan) {
      case 'solo':
        return 1;
      case 'duo':
        return 2;
      case 'trio':
        return 3;
      case 'unity':
        return 6;
      default:
        return 0;
    }
  }

  Future<void> _openSubscriptionSheet() async {
    String selected = 'solo';
    String paymentMethod = 'upi';
    String? modalError;
    bool busy = false;

    final me = await _api.fetchMe();
    final userId = me['id'].toString();
    if (!mounted) return;

    await showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> pay() async {
              setModalState(() {
                busy = true;
                modalError = null;
              });
              try {
                await _api.selectSubscription(userId: userId, plan: selected);
                await _api.confirmSubscription(userId: userId);
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                showTopNotification(
                  this.context,
                  "${t('subscription')} ${t('updated')}: ${selected.toUpperCase()}",
                );
              } catch (e) {
                setModalState(() {
                  busy = false;
                  modalError = e.toString().replaceFirst('Exception: ', '');
                });
              }
            }

            Widget planCard(String plan) {
              final picked = selected == plan;
              final border = picked
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.12);
              return Expanded(
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: isDark ? 10 : 6,
                  shadowColor:
                      Colors.black.withValues(alpha: isDark ? 0.18 : 0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: border, width: picked ? 1.5 : 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: busy
                        ? null
                        : () => setModalState(() => selected = plan),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t(plan),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Rs ${_planPrice(plan)} / ${t('month')}",
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "${t('up_to')} ${_planLimit(plan)} ${t('platforms')}",
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.72),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }

            Widget payMethod(String id, IconData icon, String label) {
              final picked = paymentMethod == id;
              return Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => setModalState(() => paymentMethod = id),
                  icon: Icon(icon, size: 18),
                  label: Text(label, overflow: TextOverflow.ellipsis),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: picked
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.12),
                      width: picked ? 1.5 : 1,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 12),
                  ),
                ),
              );
            }

            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SafeArea(
                top: true,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final usable = constraints.maxHeight - bottomInset;
                    final height = max(
                      360.0,
                      min(usable - 8, constraints.maxHeight - 8),
                    );

                    return SizedBox(
                      height: height,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                t('subscription_plans'),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  planCard('solo'),
                                  const SizedBox(width: 10),
                                  planCard('duo'),
                                  const SizedBox(width: 10),
                                  planCard('trio'),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Text(
                                t('payment_method'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  payMethod('upi', Icons.qr_code_2, t('upi')),
                                  const SizedBox(width: 10),
                                  payMethod(
                                      'card', Icons.credit_card, t('card')),
                                  const SizedBox(width: 10),
                                  payMethod('net', Icons.account_balance,
                                      t('net_banking')),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (modalError != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Text(
                                    modalError!,
                                    style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              FilledButton(
                                onPressed: busy ? null : pay,
                                child: Text(
                                    "${t('pay_now')} Rs ${_planPrice(selected)}"),
                              ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => Navigator.of(sheetContext).pop(),
                                child: Text(t('cancel')),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openPlatformPopup(_PlatformState platform) async {
    String? modalError;
    bool busy = false;

    await showAnimatedDialog<void>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;

        bool hasPlan = false;
        bool planChecked = false;
        Map<String, dynamic> subscription = {};
        Set<String> slotHistory = <String>{};
        int? slotUsed;
        int? slotLimit;

        Future<void> loadPlan(StateSetter setModalState) async {
          if (planChecked) return;
          planChecked = true;
          try {
            final me = await _api.fetchMe();
            final sub = await _api.fetchSubscription(me['id'].toString());
            final active = (sub['activePlan'] ?? '').toString().trim();
            final hist = (sub['historyPlatforms'] as List?) ?? const [];
            setModalState(() {
              subscription = Map<String, dynamic>.from(sub);
              hasPlan = active.isNotEmpty;
              slotHistory = hist
                  .map((e) => e.toString().trim().toLowerCase())
                  .where((e) => e.isNotEmpty)
                  .toSet();
              slotUsed = int.tryParse((sub['used'] ?? '').toString());
              slotLimit = int.tryParse((sub['limit'] ?? '').toString());
            });
          } catch (_) {
            setModalState(() {
              subscription = {};
              hasPlan = false;
              slotHistory = <String>{};
              slotUsed = null;
              slotLimit = null;
            });
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            final activePlan =
                (subscription['activePlan'] ?? '').toString().trim();
            final capReached = (slotLimit != null &&
                slotUsed != null &&
                slotUsed! >= slotLimit!);
            final platformKey = platform.name.toLowerCase();
            final canConnectThisPlatform = hasPlan &&
                (!capReached ||
                    platform.verified ||
                    slotHistory.contains(platformKey));

            loadPlan(setModalState);
            Future<void> sendOtp() async {
              final phone = platform.phoneController.text.trim();
              if (phone.length != 10) {
                setModalState(() => modalError = t('enter_valid_mobile'));
                return;
              }

              final otp = _randomOtp().toString();
              setState(() {
                platform.mockOtp = otp;
                platform.otpSent = true;
                platform.verified = false;
              });
              setModalState(() => modalError = null);
            }

            Future<void> verifyOtp() async {
              final entered = platform.otpController.text.trim();
              if (!platform.otpSent || platform.mockOtp == null) {
                setModalState(() => modalError = t('send_otp_first'));
                return;
              }
              if (entered != platform.mockOtp) {
                setModalState(() => modalError =
                    '${t('invalid_otp_for')} ${platform.displayName}');
                return;
              }

              setModalState(() {
                busy = true;
                modalError = null;
              });

              try {
                await _api.connectPlatform(platform: platform.name);
                if (!dialogContext.mounted) return;

                setState(() {
                  platform.verified = true;
                  platform.otpSent = false;
                  platform.otpController.clear();
                });

                showTopNotification(
                  dialogContext,
                  '${platform.displayName} ${t('verified_successfully')}',
                );
                Navigator.of(dialogContext).pop();
              } catch (e) {
                final msg = e.toString().replaceFirst('Exception: ', '');
                if (msg.contains('Subscription required') ||
                    msg.contains('Plan limit reached')) {
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (mounted) showTopNotification(this.context, msg);
                  if (mounted) _openSubscriptionSheet();
                  return;
                }
                setModalState(() {
                  busy = false;
                  modalError = msg;
                });
              }
            }

            return AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : const Color(0x261E3A8A),
                ),
              ),
              backgroundColor: Theme.of(dialogContext).colorScheme.surface,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.transparent,
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.14),
                      ),
                    ),
                    child: SizedBox.square(
                        dimension: 26, child: _brandLogo(platform, radius: 10)),
                  ),
                  const SizedBox(width: 10),
                  Text(platform.displayName.toUpperCase()),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!hasPlan) ...[
                    Text(
                      t('subscription_required'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        _openSubscriptionSheet();
                      },
                      icon: const Icon(Icons.workspace_premium_outlined,
                          size: 18),
                      label: Text(t('plans')),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (hasPlan &&
                      capReached &&
                      !slotHistory.contains(platformKey) &&
                      !platform.verified) ...[
                    Text(
                      t('plan_limit_reached'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t('plan_slots_note'),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        _openSubscriptionSheet();
                      },
                      icon: const Icon(Icons.workspace_premium_outlined,
                          size: 18),
                      label: Text(t('plans')),
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    enabled: canConnectThisPlatform,
                    controller: platform.phoneController,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: InputDecoration(
                      labelText: t('registered_mobile'),
                      hintText: t('mobile_hint'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed:
                        (busy || !canConnectThisPlatform) ? null : sendOtp,
                    child: Text(t('send_otp')),
                  ),
                  if (platform.otpSent && !platform.verified) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: platform.otpController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: t('enter_otp')),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${t('otp_generated')} ${platform.mockOtp ?? ''}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : verifyOtp,
                      child: Text(t('verify_otp')),
                    ),
                  ],
                  if (modalError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      modalError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed:
                        busy ? null : () => Navigator.of(dialogContext).pop(),
                    child: Text(t('cancel')),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _continue() {
    final verifiedCount =
        _platforms.where((p) => p.verified && p.isAvailable).length;
    if (verifiedCount == 0) {
      setState(() => _error = t('verify_one_platform'));
      return;
    }
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    final visiblePlatforms = _platforms.where((p) => p.isAvailable).toList()
      ..sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        title: Text(t('integrate_gig_platforms')),
        actions: [
          TextButton.icon(
            onPressed: _openSubscriptionSheet,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(36, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.workspace_premium_outlined, size: 16),
            label: Text(_plansHeaderLabel()),
          ),
          TextButton(
              onPressed: widget.onCycleLanguage,
              child: Text(AppStrings.label(widget.language))),
          IconButton(
            onPressed: widget.onToggleTheme,
            icon: Icon(widget.isDarkMode ? Icons.wb_sunny : Icons.brightness_2),
          ),
          IconButton(
              onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 12),
          Text(t('connect_gig_platforms'),
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(t('integration_hint')),
          const SizedBox(height: 12),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visiblePlatforms.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) =>
                _platformTile(visiblePlatforms[index]),
          ),
          const SizedBox(height: 14),
          FilledButton(
              onPressed: _continue, child: Text(t('continue_dashboard'))),
        ],
      ),
    );
  }

  Widget _brandLogo(_PlatformState platform, {double radius = 16}) {
    final name = platform.name.toLowerCase();
    const fit = BoxFit.contain;
    final needsLightBackdrop = name == 'ola';

    final logoUrl = (platform.logoUrl ?? '').trim();
    final hasNetworkLogo = logoUrl.isNotEmpty;
    final hasAssetLogo = platform.assetPath.trim().isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: needsLightBackdrop ? Colors.white : Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            hasNetworkLogo
                ? _logoFromUrl(
                    logoUrl,
                    fit: fit,
                    alignment: Alignment.center,
                    fallbackColor: platform.brand,
                    size: 24,
                  )
                : (hasAssetLogo
                    ? (platform.assetPath.toLowerCase().endsWith('.svg')
                        ? SvgPicture.asset(
                            platform.assetPath,
                            fit: fit,
                            alignment: Alignment.center,
                          )
                        : Image.asset(
                            platform.assetPath,
                            fit: fit,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.high,
                            errorBuilder: (context, error, stackTrace) => Icon(
                              Icons.link,
                              color: platform.brand,
                              size: 24,
                            ),
                          ))
                    : const SizedBox.shrink()),
            if (!hasNetworkLogo && !hasAssetLogo)
              Center(
                child: Icon(
                  Icons.link,
                  color: platform.brand,
                  size: 24,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _platformTile(_PlatformState platform) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(18);

    final side = BorderSide(
      color: platform.verified
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
      width: platform.verified ? 1.4 : 1,
    );

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: isDark ? 10 : 6,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.18 : 0.10),
      shape: RoundedRectangleBorder(borderRadius: radius, side: side),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _openPlatformPopup(platform),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 54,
                width: 54,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.transparent,
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.14),
                  ),
                ),
                child: _brandLogo(platform, radius: 16),
              ),
              const SizedBox(height: 10),
              Text(
                platform.displayName.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                platform.verified ? t('connected') : t('connect'),
                style: TextStyle(
                  color: platform.verified
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
