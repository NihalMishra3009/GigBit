import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/app_strings.dart';
import '../../core/base_url.dart';
import '../../core/device_notification_service.dart';
import '../../core/notification_history.dart';
import '../../core/overlay_animations.dart';
import '../../core/top_notification.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.token,
    required this.onLogout,
    required this.onToggleTheme,
    required this.onCycleLanguage,
    required this.isDarkMode,
    required this.language,
  });

  final String token;
  final VoidCallback onLogout;
  final VoidCallback onToggleTheme;
  final VoidCallback onCycleLanguage;
  final bool isDarkMode;
  final AppLanguage language;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _IntegrationPlatformState {
  _IntegrationPlatformState({
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

class _ChatMessage {
  _ChatMessage._(this.text, this.isUser);

  final String text;
  final bool isUser;

  factory _ChatMessage.user(String text) => _ChatMessage._(text, true);
  factory _ChatMessage.bot(String text) => _ChatMessage._(text, false);
}

enum _PlatformLegendSort { connected, disconnected, neverConnected }

class _DashboardScreenState extends State<DashboardScreen> {
  static const _kDashboardCacheKey = 'dashboard_cache_v1';
  static const Duration _kTabSlideDuration = Duration(milliseconds: 420);
  static const Duration _kAutoPlatformSyncInterval = Duration(hours: 6);
  static const Duration _kPlatformCatalogRefreshInterval =
      Duration(seconds: 8);
  static const Map<String, String> _defaultPlatformAssets = {
    'zomato': 'assets/platforms/zomato.png',
    'blinkit': 'assets/platforms/blinkit.png',
    'rapido': 'assets/platforms/rapido.png',
    'ola': 'assets/platforms/ola.png',
  };
  static const Map<String, Color> _defaultPlatformBrands = {
    'zomato': Color(0xFFE53935),
    'blinkit': Color(0xFFF5C518),
    'rapido': Color(0xFFFFC107),
    'ola': Color(0xFF8BC34A),
  };
  final _platformController = TextEditingController(text: 'zomato');
  final _amountController = TextEditingController();
  final _withdrawalController = TextEditingController();
  final _expenseAmountController = TextEditingController();
  final _expenseCategoryController = TextEditingController(text: 'fuel');
  final _profileNameController = TextEditingController();
  final _profileNewEmailController = TextEditingController();
  final _profileOldEmailOtpController = TextEditingController();
  final _profileNewEmailOtpController = TextEditingController();
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _upiIdController = TextEditingController();
  final _bankAccountController = TextEditingController();
  final _ifscController = TextEditingController();

  final _editDailyFuelController = TextEditingController();
  final _editDailyRentController = TextEditingController();
  final _integrationSearchController = TextEditingController();

  final _taxChatController = TextEditingController();
  final FocusNode _taxChatInputFocusNode = FocusNode();
  final List<_ChatMessage> _taxChatMessages = [];

  final List<_IntegrationPlatformState> _integrationPlatforms = [
    _IntegrationPlatformState(
      name: 'zomato',
      assetPath: 'assets/platforms/zomato.png',
      logoBackground: const Color(0xFFE53935),
      brand: const Color(0xFFE53935),
    ),
    _IntegrationPlatformState(
      name: 'blinkit',
      assetPath: 'assets/platforms/blinkit.png',
      logoBackground: const Color(0xFFF5C518),
      brand: const Color(0xFFF5C518),
    ),
    _IntegrationPlatformState(
      name: 'rapido',
      assetPath: 'assets/platforms/rapido.png',
      logoBackground: Colors.white,
      brand: const Color(0xFFFFC107),
    ),
    _IntegrationPlatformState(
      name: 'ola',
      assetPath: 'assets/platforms/ola.png',
      logoBackground: Colors.white,
      brand: const Color(0xFF8BC34A),
    ),
  ];

  int _section = 0;
  bool _platformBreakdownExpanded = false;
  bool _expenseDetailsExpanded = false;
  bool _activePlansExpanded = false;
  bool _integrationSearchOpen = false;
  _PlatformLegendSort? _integrationSortPriority;
  String _expensePeriod = 'daily';
  double? _taxFabLeft;
  double? _taxFabTop;
  bool _taxHistoryPanelOpen = false;
  bool _insuranceClaimsExpanded = false;
  bool _insuranceContributionsExpanded = false;
  bool _loanClaimsExpanded = false;
  bool _taxChatInputUnlocked = false;
  int _taxInputTapBlockedUntilMs = 0;
  String? _activeTaxChatId;
  String? _taxLoadedChatId;
  List<Map<String, dynamic>> _taxChats = [];
  bool _oldPasswordVerified = false;
  bool _oldPasswordVisible = false;
  bool _newPasswordVisible = false;
  String? _passwordVerifyToken;
  String? _emailChangeFlowId;
  bool _emailOldOtpSent = false;
  bool _emailOldOtpVerified = false;
  bool _emailNewOtpSent = false;
  List<dynamic> _subscriptionPurchases = [];
  List<dynamic> _expenses = [];
  bool _loading = false;
  String? _error;
  StreamSubscription<void>? _platformCatalogEventsSub;
  StreamSubscription<Map<String, dynamic>>? _approvalUpdatesSub;
  Timer? _autoPlatformSyncTimer;
  Timer? _platformCatalogPollTimer;
  bool _autoPlatformSyncInFlight = false;
  String _lastCatalogSignature = '';

  Map<String, dynamic> _me = {};
  Map<String, dynamic> _summary = {};
  Map<String, dynamic> _loan = {'score': 0, 'limit': 0};
  Map<String, dynamic> _subscription = {};
  List<dynamic> _transactions = [];
  List<dynamic> _contributions = [];
  List<dynamic> _insuranceClaims = [];
  List<dynamic> _loanRequests = [];

  String get _baseUrl => resolveApiBaseUrl();
  ApiClient get _api => ApiClient(baseUrl: _baseUrl, token: widget.token);
  String t(String key) => AppStrings.t(widget.language, key);
  String _taxLanguageCode() {
    switch (widget.language) {
      case AppLanguage.hi:
        return 'hi';
      case AppLanguage.mr:
        return 'mr';
      case AppLanguage.en:
        return 'en';
    }
  }

  String _tr3(String en, String hi, String mr) {
    switch (widget.language) {
      case AppLanguage.hi:
        return hi;
      case AppLanguage.mr:
        return mr;
      case AppLanguage.en:
        return en;
    }
  }

  Color _parseColorOrFallback(String? value, Color fallback) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return fallback;
    final hex = raw.replaceFirst('#', '');
    if (hex.length != 6 && hex.length != 8) return fallback;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return fallback;
    return Color(hex.length == 6 ? (0xFF000000 | parsed) : parsed);
  }

  Widget _logoFromUrl(
    String logoUrl, {
    required BoxFit fit,
    required Alignment alignment,
    required Color fallbackColor,
    double size = 22,
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

  String _planLimitLabel() {
    final limitRaw = _subscription['limit'];
    final limit =
        limitRaw is num ? limitRaw.toInt() : int.tryParse('$limitRaw');
    if (limit != null && limit > 0) return '$limit';
    return '0';
  }

  void _syncIntegrationFlags(List<dynamic> platforms) {
    final connected = platforms
        .map((e) => e.toString().trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    for (final p in _integrationPlatforms) {
      p.verified = connected.contains(p.name.toLowerCase());
    }
  }

  void _applyPlatformCatalog(List<dynamic> catalogItems) {
    final catalogBySlug = <String, Map<String, dynamic>>{};
    for (final item in catalogItems) {
      if (item is Map<String, dynamic>) {
        final slug = (item['slug'] ?? '').toString().trim().toLowerCase();
        if (slug.isNotEmpty) catalogBySlug[slug] = item;
      } else if (item is Map) {
        final slug = (item['slug'] ?? '').toString().trim().toLowerCase();
        if (slug.isNotEmpty)
          catalogBySlug[slug] = Map<String, dynamic>.from(item);
      }
    }
    final enabledSlugs = catalogBySlug.keys.toSet();
    final stateBySlug = <String, _IntegrationPlatformState>{
      for (final p in _integrationPlatforms) p.name.toLowerCase(): p,
    };

    for (final slug in enabledSlugs) {
      if (!stateBySlug.containsKey(slug)) {
        final fallbackBrand =
            _defaultPlatformBrands[slug] ?? const Color(0xFF1E3A8A);
        stateBySlug[slug] = _IntegrationPlatformState(
          name: slug,
          assetPath: _defaultPlatformAssets[slug] ?? '',
          logoBackground: fallbackBrand,
          brand: fallbackBrand,
        );
      }
    }

    final sorted = stateBySlug.values.toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    _integrationPlatforms
      ..clear()
      ..addAll(sorted);

    for (final p in _integrationPlatforms) {
      final item = catalogBySlug[p.name.toLowerCase()];
      p.displayName = (item?['name'] ?? p.name).toString();
      final fallbackBrand =
          _defaultPlatformBrands[p.name.toLowerCase()] ?? p.brand;
      p.logoUrl = item == null
          ? null
          : ((item['logo_url'] ?? '').toString().trim().isEmpty
              ? null
              : (item['logo_url'] ?? '').toString().trim());
      p.logoBackground = _parseColorOrFallback(
        item?['logo_bg_color']?.toString(),
        fallbackBrand,
      );
      p.isAvailable = enabledSlugs.contains(p.name.toLowerCase());
      if (!p.isAvailable) {
        p.verified = false;
      }
    }
  }

  String _catalogSignature(List<dynamic> catalogItems) {
    final rows = <String>[];
    for (final raw in catalogItems) {
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
    return rows.join('||');
  }

  Future<void> _refreshPlatformCatalogOnly() async {
    try {
      final catalog = await _api.fetchPlatformCatalog();
      final nextSignature = _catalogSignature(catalog);
      if (_lastCatalogSignature == nextSignature) return;
      if (!mounted) return;
      setState(() {
        _lastCatalogSignature = nextSignature;
        _applyPlatformCatalog(catalog);
      });
    } catch (_) {
      // ignore transient API/network failures
    }
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  bool get _isInsured {
    final v = _me['gigbitInsurance'] ?? _me['gigbit_insurance'];
    if (v is bool) return v;
    return v?.toString().toLowerCase() == 'true';
  }

  double get _walletBalance {
    final totalEarnings = _toDouble(_summary['totalEarnings']);
    final totalWithdrawn = _toDouble(_summary['totalWithdrawn']);
    final computed = totalEarnings - totalWithdrawn;
    if (computed >= 0) return computed;
    return 0;
  }

  Map<String, double> get _platformBreakdown {
    // Connected platforms only; values are cumulative synced earnings.
    final connected = _integrationPlatforms
        .where((p) => p.verified && p.isAvailable)
        .map((p) => p.name.toLowerCase())
        .toSet();
    final map = <String, double>{};
    for (final key in connected) {
      map[key] = _platformEarningsByKey[key] ?? 0;
    }
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {for (final e in sorted) e.key: e.value};
  }

  Map<String, double> get _platformEarningsByKey {
    final enabledKeys = _integrationPlatforms
        .where((p) => p.isAvailable)
        .map((p) => p.name.toLowerCase())
        .toSet();
    final out = <String, double>{};
    for (final tx in _transactions) {
      final name = (tx['platform']?.toString().trim().isNotEmpty ?? false)
          ? tx['platform'].toString().trim().toLowerCase()
          : 'other';
      if (!enabledKeys.contains(name)) continue;
      out[name] = (out[name] ?? 0) + _toDouble(tx['amount']);
    }
    return out;
  }

  int _tripUnitsFromTx(dynamic tx) {
    final raw = tx['trips'] ?? tx['tripCount'] ?? tx['trip_count'];
    if (raw is num) {
      final n = raw.toInt();
      return n > 0 ? n : 1;
    }
    if (raw is String) {
      final n = int.tryParse(raw.trim());
      if (n != null && n > 0) return n;
    }
    final note = (tx['note'] ?? '').toString().toLowerCase();
    final m = RegExp(r'trips\s*:\s*(\d+)').firstMatch(note);
    if (m != null) {
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > 0) return n;
    }
    return 1;
  }

  Map<String, int> get _platformTripCounts {
    final enabledKeys = _integrationPlatforms
        .where((p) => p.isAvailable)
        .map((p) => p.name.toLowerCase())
        .toSet();
    final out = <String, int>{};
    for (final tx in _transactions) {
      final name = (tx['platform']?.toString().trim().isNotEmpty ?? false)
          ? tx['platform'].toString().trim().toLowerCase()
          : 'other';
      if (!enabledKeys.contains(name)) continue;
      out[name] = (out[name] ?? 0) + _tripUnitsFromTx(tx);
    }
    return out;
  }

  int get _totalTrips =>
      _platformTripCounts.values.fold<int>(0, (a, b) => a + b);

  Map<String, double> get _platformTodayEarningsByKey {
    final out = <String, double>{};
    final nowIst = _toIst(DateTime.now());
    final today = DateTime(nowIst.year, nowIst.month, nowIst.day);
    for (final tx in _transactions) {
      final name = (tx['platform']?.toString().trim().isNotEmpty ?? false)
          ? tx['platform'].toString().trim().toLowerCase()
          : 'other';
      final createdRaw = tx['created_at'] ?? tx['createdAt'];
      final dt =
          createdRaw == null ? null : DateTime.tryParse(createdRaw.toString());
      if (dt == null) continue;
      final ist = _toIst(dt);
      final day = DateTime(ist.year, ist.month, ist.day);
      if (day != today) continue;
      out[name] = (out[name] ?? 0) + _toDouble(tx['amount']);
    }
    return out;
  }

  Map<String, int> get _platformTodayTripCounts {
    final out = <String, int>{};
    final nowIst = _toIst(DateTime.now());
    final today = DateTime(nowIst.year, nowIst.month, nowIst.day);
    for (final tx in _transactions) {
      final name = (tx['platform']?.toString().trim().isNotEmpty ?? false)
          ? tx['platform'].toString().trim().toLowerCase()
          : 'other';
      final createdRaw = tx['created_at'] ?? tx['createdAt'];
      final dt =
          createdRaw == null ? null : DateTime.tryParse(createdRaw.toString());
      if (dt == null) continue;
      final ist = _toIst(dt);
      final day = DateTime(ist.year, ist.month, ist.day);
      if (day != today) continue;
      out[name] = (out[name] ?? 0) + _tripUnitsFromTx(tx);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _restoreCachedDashboard();
    _load(showLoader: false);
    _loadTaxChats();
    _platformCatalogEventsSub = _api.platformCatalogEvents().listen((_) {
      if (!mounted) return;
      _refreshPlatformCatalogOnly();
    });
    _platformCatalogPollTimer =
        Timer.periodic(_kPlatformCatalogRefreshInterval, (_) {
      if (!mounted) return;
      _refreshPlatformCatalogOnly();
    });
    _approvalUpdatesSub = _api.approvalUpdateEvents().listen((event) {
      _handleApprovalUpdateEvent(event);
    });
    _autoPlatformSyncTimer =
        Timer.periodic(_kAutoPlatformSyncInterval, (_) async {
      if (!mounted || _autoPlatformSyncInFlight) return;
      _autoPlatformSyncInFlight = true;
      try {
        await _syncAllConnectedPlatformsRandom(notify: false);
      } finally {
        _autoPlatformSyncInFlight = false;
      }
    });
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  List<dynamic> _asList(dynamic value) {
    if (value is List) return List<dynamic>.from(value);
    return <dynamic>[];
  }

  Future<void> _restoreCachedDashboard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDashboardCacheKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final data = Map<String, dynamic>.from(decoded);
      final catalog = _asList(data['platformCatalog']);
      final platforms = _asList(data['platforms']);
      _applyPlatformCatalog(catalog);
      _syncIntegrationFlags(platforms);
      if (!mounted) return;
      setState(() {
        _me = _asMap(data['me']);
        _summary = _asMap(data['summary']);
        _loan = _asMap(data['loan']);
        _subscription = _asMap(data['subscription']);
        _transactions = _asList(data['transactions']);
        _contributions = _asList(data['contributions']);
        _insuranceClaims = _asList(data['insuranceClaims']);
        _loanRequests = _asList(data['loanRequests']);
        _subscriptionPurchases = _asList(data['subscriptionPurchases']);
        _expenses = _asList(data['expenses']);
      });
    } catch (_) {
      // Ignore malformed cache and continue with live fetch.
    }
  }

  Future<void> _cacheDashboardSnapshot({
    required Map<String, dynamic> me,
    required Map<String, dynamic> summary,
    required Map<String, dynamic> loan,
    required Map<String, dynamic> subscription,
    required List<dynamic> transactions,
    required List<dynamic> contributions,
    required List<dynamic> insuranceClaims,
    required List<dynamic> loanRequests,
    required List<dynamic> purchases,
    required List<dynamic> expenses,
    required List<dynamic> catalog,
    required List<dynamic> platforms,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'me': me,
        'summary': summary,
        'loan': loan,
        'subscription': subscription,
        'transactions': transactions,
        'contributions': contributions,
        'insuranceClaims': insuranceClaims,
        'loanRequests': loanRequests,
        'subscriptionPurchases': purchases,
        'expenses': expenses,
        'platformCatalog': catalog,
        'platforms': platforms,
      };
      await prefs.setString(_kDashboardCacheKey, jsonEncode(payload));
    } catch (_) {
      // Ignore cache write failures.
    }
  }

  void _ensureTaxGreeting() {
    if (_taxChatMessages.isNotEmpty) return;
    _taxChatMessages.add(_ChatMessage.bot(t('tax_bot_greeting')));
  }

  Future<void> _loadTaxChats({bool ensureSelection = true}) async {
    try {
      final rows = await _api.fetchTaxAssistantChats(limit: 120);
      final chats = rows
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      String? selected = _activeTaxChatId;
      if (ensureSelection) {
        final hasSelected =
            selected != null && chats.any((c) => '${c['id']}' == selected);
        if (!hasSelected) {
          selected = chats.isNotEmpty ? '${chats.first['id']}' : null;
        }
      }
      if (!mounted) return;
      setState(() {
        _taxChats = chats;
        _activeTaxChatId = selected;
      });
    } catch (_) {
      // Keep local in-memory chat if fetch fails.
    }
  }

  Future<void> _createNewTaxChat() async {
    if (!mounted) return;
    setState(() {
      _activeTaxChatId = null;
      _taxLoadedChatId = null;
      _taxChatMessages.clear();
    });
    _ensureTaxGreeting();
  }

  String _currentTaxChatTitle() {
    final id = _activeTaxChatId;
    if (id == null || id.isEmpty) return _tr3('New Chat', 'नई चैट', 'नवी चॅट');
    final chat = _taxChats.firstWhere(
      (c) => '${c['id']}' == id,
      orElse: () => <String, dynamic>{},
    );
    final title = (chat['title'] ?? '').toString().trim();
    return title.isEmpty ? _tr3('New Chat', 'नई चैट', 'नवी चॅट') : title;
  }

  Future<void> _renameCurrentTaxChat() async {
    String? id = _activeTaxChatId;
    if (id == null || id.isEmpty || id == '__legacy__') {
      final firstReal = _taxChats.firstWhere(
        (c) {
          final cid = (c['id'] ?? '').toString().trim();
          return cid.isNotEmpty && cid != '__legacy__';
        },
        orElse: () => <String, dynamic>{},
      );
      final fallback = (firstReal['id'] ?? '').toString().trim();
      if (fallback.isEmpty) return;
      id = fallback;
      _activeTaxChatId = fallback;
      _taxLoadedChatId = null;
      await _loadTaxChatHistory(force: true);
      if (!mounted) return;
      setState(() {});
    }
    await _renameTaxChatById(id, initialTitle: _currentTaxChatTitle());
  }

  Future<void> _renameTaxChatById(
    String id, {
    String? initialTitle,
  }) async {
    if (id.trim().isEmpty || id == '__legacy__') return;
    final controller = TextEditingController(text: _currentTaxChatTitle());
    if (initialTitle != null && initialTitle.trim().isNotEmpty) {
      controller.text = initialTitle.trim();
    }
    final next = await showAnimatedDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr3('Rename chat', 'चैट का नाम बदलें', 'चॅटचे नाव बदला')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: _tr3('Chat name', 'चैट नाम', 'चॅट नाव'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(_tr3('Save', 'सेव करें', 'सेव्ह करा')),
          ),
        ],
      ),
    );
    final name = (next ?? '').trim();
    if (name.isEmpty) return;
    try {
      await _api.renameTaxAssistantChat(chatId: id, title: name);
      await _loadTaxChats(ensureSelection: false);
    } catch (_) {}
  }

  Future<bool> _deleteTaxChatById(
    String id, {
    required String title,
  }) async {
    if (id.trim().isEmpty) return false;
    final confirmed = await showAnimatedDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr3('Delete chat', 'चैट हटाएं', 'चॅट हटवा')),
        content: Text(
          _tr3(
            'Delete "$title"? This cannot be undone.',
            '"$title" हटाएं? इसे वापस नहीं लाया जा सकता।',
            '"$title" हटवायची? हे परत आणता येणार नाही.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(_tr3('Delete', 'हटाएं', 'हटवा')),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    try {
      final deletedId = id.trim();
      final deletedActive = _activeTaxChatId == deletedId;
      final deletedLoaded = _taxLoadedChatId == deletedId;
      final remainingLocal = _taxChats
          .where((c) => (c['id'] ?? '').toString().trim() != deletedId)
          .toList();

      if (mounted) {
        setState(() {
          _taxChats = remainingLocal;
          if (deletedActive) {
            // If currently open chat is deleted, jump to chatbot default chat.
            _activeTaxChatId = null;
          }
          if (deletedActive || deletedLoaded) {
            _taxChatMessages.clear();
            _taxLoadedChatId = null;
            _taxChatInputUnlocked = false;
            _taxChatInputFocusNode.unfocus();
            _taxChatInputFocusNode.canRequestFocus = false;
            _taxInputTapBlockedUntilMs =
                DateTime.now().millisecondsSinceEpoch + 500;
          }
        });
      }

      await _api.deleteTaxAssistantChat(chatId: deletedId);
      await _loadTaxChats(ensureSelection: false);

      if (!mounted) return true;
      if (deletedActive || deletedLoaded) {
        _ensureTaxGreeting();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadTaxChatHistory({
    bool force = false,
    int limit = 120,
  }) async {
    final chatId = _activeTaxChatId;
    if (chatId == null || chatId.isEmpty) return;
    if (!force && _taxLoadedChatId == chatId) return;
    try {
      final rows =
          await _api.fetchTaxAssistantHistory(limit: limit, chatId: chatId);
      final loaded = <_ChatMessage>[];
      for (final row in rows) {
        final question = (row['question'] ?? '').toString().trim();
        final answer = (row['answer'] ?? '').toString().trim();
        if (question.isNotEmpty) loaded.add(_ChatMessage.user(question));
        if (answer.isNotEmpty) loaded.add(_ChatMessage.bot(answer));
      }
      if (!mounted) return;
      setState(() {
        _taxChatMessages
          ..clear()
          ..addAll(loaded);
        _taxLoadedChatId = chatId;
      });
    } catch (_) {
      // Keep local in-memory chat if history fetch fails.
    }
  }

  Future<void> _openTaxChatbot() async {
    FocusManager.instance.primaryFocus?.unfocus();
    _taxChatInputUnlocked = false;
    _taxChatInputFocusNode.unfocus();
    _taxChatInputFocusNode.canRequestFocus = false;
    _ensureTaxGreeting();

    var bootstrapStarted = false;
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      requestFocus: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (context, setModalState) {
            if (!bootstrapStarted) {
              bootstrapStarted = true;
              unawaited(() async {
                await Future<void>.delayed(const Duration(milliseconds: 460));
                await _loadTaxChats(ensureSelection: true);
                await _loadTaxChatHistory(force: true, limit: 120);
                if (!mounted || !context.mounted) return;
                setModalState(() {});
              }());
            }

            Future<void> send() async {
              final text = _taxChatController.text.trim();
              if (text.isEmpty) return;
              _taxChatController.clear();

              setModalState(() {
                _taxChatMessages.add(_ChatMessage.user(text));
              });

              final beforeChatId = _activeTaxChatId;
              final reply =
                  await _taxAssistantReply(text, chatId: beforeChatId);
              if (!mounted || !context.mounted) return;
              final nextChatId = (reply['chatId'] ?? '').trim();
              setModalState(() {
                _taxChatMessages.add(_ChatMessage.bot(reply['answer'] ?? ''));
                if (nextChatId.isNotEmpty) {
                  _activeTaxChatId = nextChatId;
                }
              });
              if (nextChatId.isNotEmpty) {
                _taxLoadedChatId = nextChatId;
              } else {
                _taxLoadedChatId = beforeChatId;
              }
              await _loadTaxChats(ensureSelection: false);
              if (!context.mounted) return;
              setModalState(() {});
            }

            return AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final usable = constraints.maxHeight - bottomInset;
                    final height = math.max(
                      320.0,
                      math.min(usable - 24, constraints.maxHeight * 0.82),
                    );

                    return SizedBox(
                      height: height,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        gradient: LinearGradient(
                                          colors: [
                                            Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            Theme.of(context)
                                                .colorScheme
                                                .secondary,
                                          ],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.16),
                                            blurRadius: 16,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                      ),
                                      child: const Icon(
                                        Icons.chat_bubble_outline,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            t('tax_assistant'),
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          Text(
                                            _currentTaxChatTitle(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.7),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: _tr3('Chat history',
                                          'चैट हिस्ट्री', 'चॅट इतिहास'),
                                      onPressed: () => setModalState(() {
                                        _taxHistoryPanelOpen =
                                            !_taxHistoryPanelOpen;
                                      }),
                                      icon: const Icon(Icons.history),
                                    ),
                                    IconButton(
                                      tooltip: _tr3('Rename chat',
                                          'चैट का नाम बदलें', 'चॅटचे नाव बदला'),
                                      onPressed: () async {
                                        await _renameCurrentTaxChat();
                                        if (!context.mounted) return;
                                        setModalState(() {});
                                      },
                                      icon: const Icon(
                                          Icons.drive_file_rename_outline),
                                    ),
                                    IconButton(
                                      tooltip: t('cancel'),
                                      onPressed: () =>
                                          Navigator.of(context).maybePop(),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      color: isDark
                                          ? const Color(0xFF0B1020)
                                          : const Color(0xFFF8FAFC),
                                      border: Border.all(
                                        color: isDark
                                            ? Colors.white
                                                .withValues(alpha: 0.10)
                                            : const Color(0x261E3A8A),
                                      ),
                                    ),
                                    child: ListView.builder(
                                      padding: const EdgeInsets.all(12),
                                      itemCount: _taxChatMessages.length,
                                      itemBuilder: (context, index) {
                                        final msg = _taxChatMessages[index];
                                        final isUser = msg.isUser;
                                        final bubbleColor = isUser
                                            ? Theme.of(context)
                                                .colorScheme
                                                .secondary
                                            : Theme.of(context)
                                                .colorScheme
                                                .surface;
                                        final textColor = isUser
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSecondary
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface;

                                        return Align(
                                          alignment: isUser
                                              ? Alignment.centerRight
                                              : Alignment.centerLeft,
                                          child: Container(
                                            margin: const EdgeInsets.only(
                                                bottom: 10),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                            constraints: const BoxConstraints(
                                                maxWidth: 320),
                                            decoration: BoxDecoration(
                                              color: bubbleColor,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: isUser
                                                    ? Colors.transparent
                                                    : (isDark
                                                        ? Colors.white
                                                            .withValues(
                                                            alpha: 0.08,
                                                          )
                                                        : const Color(
                                                            0x141E3A8A)),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.06),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 6),
                                                ),
                                              ],
                                            ),
                                            child: Text(
                                              msg.text,
                                              style: TextStyle(
                                                color: textColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _taxChatController,
                                        focusNode: _taxChatInputFocusNode,
                                        autofocus: false,
                                        readOnly: !_taxChatInputUnlocked,
                                        onTap: () {
                                          if (DateTime.now()
                                                  .millisecondsSinceEpoch <
                                              _taxInputTapBlockedUntilMs) {
                                            return;
                                          }
                                          if (_taxChatInputUnlocked) return;
                                          setModalState(() {
                                            _taxChatInputUnlocked = true;
                                          });
                                          _taxChatInputFocusNode
                                              .canRequestFocus = true;
                                          _taxChatInputFocusNode.requestFocus();
                                        },
                                        textInputAction: TextInputAction.send,
                                        onSubmitted: (_) {
                                          send();
                                        },
                                        decoration: InputDecoration(
                                          hintText: t('type_message'),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    FilledButton(
                                      onPressed: send,
                                      child: Text(t('send_message')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_taxHistoryPanelOpen)
                            Positioned.fill(
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: () => setModalState(() {
                                  _taxHistoryPanelOpen = false;
                                }),
                              ),
                            ),
                          Builder(builder: (ctx) {
                            final allChats = _taxChats.where((chat) {
                              final id = (chat['id'] ?? '').toString().trim();
                              return id.isNotEmpty;
                            }).toList();
                            final panelWidth =
                                math.min(280.0, constraints.maxWidth * 0.76);
                            final panelHeight = math.min(height * 0.62, 360.0);
                            const openLeft = 40.0;
                            const hiddenPeek = 10.0;
                            final closedOffsetX =
                                ((-panelWidth + hiddenPeek) - openLeft) /
                                    panelWidth;
                            final top = (height - panelHeight) / 2;
                            return Positioned(
                              left: openLeft,
                              top: top,
                              child: AnimatedSlide(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                offset: _taxHistoryPanelOpen
                                    ? Offset.zero
                                    : Offset(closedOffsetX, 0),
                                child: Container(
                                  width: panelWidth,
                                  height: panelHeight,
                                  padding:
                                      const EdgeInsets.fromLTRB(10, 10, 10, 8),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .surface
                                        .withValues(
                                            alpha: isDark ? 0.95 : 0.98),
                                    border: Border.all(
                                      color: isDark
                                          ? Colors.white.withValues(alpha: 0.12)
                                          : const Color(0x261E3A8A),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                            alpha: isDark ? 0.28 : 0.12),
                                        blurRadius: 20,
                                        offset: const Offset(0, 10),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              _tr3('Chat History',
                                                  'चैट हिस्ट्री', 'चॅट इतिहास'),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () async {
                                              await _createNewTaxChat();
                                              if (!ctx.mounted) return;
                                              setModalState(() {
                                                _taxHistoryPanelOpen = false;
                                              });
                                            },
                                            child:
                                                Text(_tr3('New', 'नई', 'नवी')),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Expanded(
                                        child: allChats.isEmpty
                                            ? Center(
                                                child: Text(
                                                  _tr3(
                                                      'No chats',
                                                      'कोई चैट नहीं',
                                                      'चॅट्स नाहीत'),
                                                  style: TextStyle(
                                                    color: Theme.of(ctx)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.7),
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              )
                                            : ListView.separated(
                                                itemCount: allChats.length,
                                                separatorBuilder: (_, __) =>
                                                    const SizedBox(height: 6),
                                                itemBuilder: (_, i) {
                                                  final chat = allChats[i];
                                                  final id = (chat['id'] ?? '')
                                                      .toString()
                                                      .trim();
                                                  final title =
                                                      (chat['title'] ?? '')
                                                          .toString()
                                                          .trim();
                                                  final safeTitle =
                                                      title.isEmpty
                                                          ? _tr3(
                                                              'Untitled',
                                                              'बिना नाम',
                                                              'शीर्षक नाही')
                                                          : title;
                                                  final canRename =
                                                      id != '__legacy__';
                                                  final isCurrent =
                                                      id == _activeTaxChatId;
                                                  return Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 8,
                                                        vertical: 6),
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              10),
                                                      color: Theme.of(ctx)
                                                          .colorScheme
                                                          .surface
                                                          .withValues(
                                                              alpha: isDark
                                                                  ? 0.42
                                                                  : 0.92),
                                                      border: Border.all(
                                                        color: isDark
                                                            ? Colors.white
                                                                .withValues(
                                                                    alpha: 0.10)
                                                            : const Color(
                                                                0x261E3A8A),
                                                      ),
                                                    ),
                                                    child: Row(
                                                      children: [
                                                        Expanded(
                                                          child: InkWell(
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        8),
                                                            onTap: () async {
                                                              if (id.isEmpty) {
                                                                return;
                                                              }
                                                              if (id ==
                                                                  _activeTaxChatId) {
                                                                setModalState(
                                                                    () {
                                                                  _taxHistoryPanelOpen =
                                                                      false;
                                                                });
                                                                return;
                                                              }
                                                              setModalState(() {
                                                                _activeTaxChatId =
                                                                    id;
                                                                _taxLoadedChatId =
                                                                    null;
                                                                _taxHistoryPanelOpen =
                                                                    false;
                                                              });
                                                              await _loadTaxChatHistory(
                                                                  force: true);
                                                              if (!ctx
                                                                  .mounted) {
                                                                return;
                                                              }
                                                              setModalState(
                                                                  () {});
                                                            },
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          2,
                                                                      vertical:
                                                                          3),
                                                              child: Text(
                                                                safeTitle,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style:
                                                                    TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                  fontSize: 12,
                                                                  color: isCurrent
                                                                      ? Theme.of(
                                                                              ctx)
                                                                          .colorScheme
                                                                          .secondary
                                                                      : null,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        IconButton(
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          constraints:
                                                              const BoxConstraints
                                                                  .tightFor(
                                                                  width: 28,
                                                                  height: 28),
                                                          tooltip: _tr3(
                                                            'Rename',
                                                            'नाम बदलें',
                                                            'नाव बदला',
                                                          ),
                                                          onPressed: canRename
                                                              ? () async {
                                                                  await _renameTaxChatById(
                                                                    id,
                                                                    initialTitle:
                                                                        safeTitle,
                                                                  );
                                                                  if (!ctx
                                                                      .mounted) {
                                                                    return;
                                                                  }
                                                                  setModalState(
                                                                      () {});
                                                                }
                                                              : null,
                                                          icon: const Icon(
                                                            Icons.edit_outlined,
                                                            size: 16,
                                                          ),
                                                        ),
                                                        IconButton(
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          constraints:
                                                              const BoxConstraints
                                                                  .tightFor(
                                                                  width: 28,
                                                                  height: 28),
                                                          tooltip: _tr3(
                                                            'Delete',
                                                            'हटाएं',
                                                            'हटवा',
                                                          ),
                                                          onPressed: () async {
                                                            final ok =
                                                                await _deleteTaxChatById(
                                                              id,
                                                              title: safeTitle,
                                                            );
                                                            if (!ok ||
                                                                !ctx.mounted) {
                                                              return;
                                                            }
                                                            setModalState(
                                                                () {});
                                                          },
                                                          icon: const Icon(
                                                            Icons
                                                                .delete_outline,
                                                            size: 16,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      _taxChatInputUnlocked = false;
      _taxChatInputFocusNode.unfocus();
      _taxChatInputFocusNode.canRequestFocus = false;
      _clearErrorAfterWindow();
    });
  }

  Future<Map<String, String?>> _taxAssistantReply(String input,
      {String? chatId}) async {
    try {
      final data = await _api.askTaxAssistant(
        question: input,
        chatId: chatId,
        languageCode: _taxLanguageCode(),
      );
      final answer = (data['answer'] ?? '').toString().trim();
      if (answer.isNotEmpty) {
        final returnedChatId =
            (data['chatId'] ?? chatId ?? '').toString().trim();
        return {'answer': answer, 'chatId': returnedChatId};
      }
    } catch (_) {
      // Fall back to local scoped response.
    }
    return {'answer': _localTaxReply(input), 'chatId': chatId};
  }

  String _localTaxReply(String input) {
    final q = input.toLowerCase();
    final inScope = [
      'tax',
      'itr',
      'income tax',
      'return',
      'filing',
      'tds',
      'gst',
      'deduction',
      '80c',
      '80d',
      '44ad',
      'gigbit',
      'platform',
      'earning',
      'expense',
      'fuel',
      'rent',
      'withdraw',
      'insurance',
      'subscription',
      'zomato',
      'blinkit',
      'rapido',
      'ola',
    ].any((term) => q.contains(term));

    if (!inScope) {
      return _tr3(
        'I can only answer Tax, ITR, and GigBit platform finance questions.',
        'मैं केवल टैक्स, ITR और GigBit प्लेटफॉर्म फाइनेंस से जुड़े सवालों का जवाब दे सकता/सकती हूं।',
        'मी फक्त टॅक्स, ITR आणि GigBit प्लॅटफॉर्म फायनान्स प्रश्नांची उत्तरे देऊ शकतो/शकते.',
      );
    }

    final earnings = _toDouble(_summary['totalEarnings']);
    final expenses = _toDouble(_summary['expenses']);
    final taxable = (earnings - expenses).clamp(0, double.infinity);
    if (q.contains('itr') || q.contains('file') || q.contains('return')) {
      return _tr3(
        'ITR Summary: Gross receipts Rs ${earnings.toStringAsFixed(0)}, expenses Rs ${expenses.toStringAsFixed(0)}, estimated taxable income Rs ${taxable.toStringAsFixed(0)}. Use Form 26AS/AIS for TDS values.',
        'ITR सारांश: कुल प्राप्ति Rs ${earnings.toStringAsFixed(0)}, खर्च Rs ${expenses.toStringAsFixed(0)}, अनुमानित कर योग्य आय Rs ${taxable.toStringAsFixed(0)}। TDS के लिए Form 26AS/AIS देखें।',
        'ITR सारांश: एकूण प्राप्ती Rs ${earnings.toStringAsFixed(0)}, खर्च Rs ${expenses.toStringAsFixed(0)}, अंदाजे करपात्र उत्पन्न Rs ${taxable.toStringAsFixed(0)}. TDS साठी Form 26AS/AIS वापरा.',
      );
    }
    if (q.contains('80c') || q.contains('deduction')) {
      return _tr3(
        'Track eligible deductions with proof bills, then include them while filing ITR.',
        'योग्य कटौतियों को बिल/प्रूफ के साथ ट्रैक करें और ITR भरते समय शामिल करें।',
        'पात्र कपातींची बिले/पुराव्यांसह नोंद ठेवा आणि ITR भरताना समाविष्ट करा.',
      );
    }
    if (q.contains('gst')) {
      return _tr3(
        'GST applicability depends on turnover and service type. Confirm threshold and registration rules.',
        'GST लागू होना टर्नओवर और सेवा प्रकार पर निर्भर करता है। थ्रेशोल्ड और रजिस्ट्रेशन नियम जांचें।',
        'GST लागू होणे टर्नओव्हर आणि सेवा प्रकारावर अवलंबून असते. थ्रेशोल्ड आणि नोंदणी नियम तपासा.',
      );
    }
    if (q.contains('tds')) {
      return _tr3(
        'Claim deducted TDS in ITR using Form 26AS/AIS values.',
        'Form 26AS/AIS के आधार पर ITR में कटा हुआ TDS क्लेम करें।',
        'Form 26AS/AIS मधील मूल्यांनुसार ITR मध्ये वजा झालेला TDS क्लेम करा.',
      );
    }
    if (q.contains('expense') ||
        q.contains('fuel') ||
        q.contains('rent') ||
        q.contains('earning')) {
      return _tr3(
        'Current estimate: Gross receipts Rs ${earnings.toStringAsFixed(0)}, expenses Rs ${expenses.toStringAsFixed(0)}, taxable Rs ${taxable.toStringAsFixed(0)}.',
        'मौजूदा अनुमान: कुल प्राप्ति Rs ${earnings.toStringAsFixed(0)}, खर्च Rs ${expenses.toStringAsFixed(0)}, कर योग्य Rs ${taxable.toStringAsFixed(0)}।',
        'सध्याचा अंदाज: एकूण प्राप्ती Rs ${earnings.toStringAsFixed(0)}, खर्च Rs ${expenses.toStringAsFixed(0)}, करपात्र Rs ${taxable.toStringAsFixed(0)}.',
      );
    }
    return _tr3(
      'Ask about Tax, ITR filing, TDS, deductions, or GigBit earnings/expense summary.',
      'टैक्स, ITR फाइलिंग, TDS, कटौती या GigBit कमाई/खर्च सारांश के बारे में पूछें।',
      'टॅक्स, ITR फाइलिंग, TDS, कपात किंवा GigBit कमाई/खर्च सारांशाबद्दल विचारा.',
    );
  }

  @override
  void dispose() {
    _integrationSearchController.dispose();
    _taxChatController.dispose();
    _taxChatInputFocusNode.dispose();
    _platformCatalogEventsSub?.cancel();
    _approvalUpdatesSub?.cancel();
    _autoPlatformSyncTimer?.cancel();
    _platformCatalogPollTimer?.cancel();
    super.dispose();
  }

  _PlatformLegendSort _platformLegendStateFor(
    _IntegrationPlatformState platform,
    Set<String> activeBoundPlatforms,
  ) {
    if (platform.verified) return _PlatformLegendSort.connected;
    if (activeBoundPlatforms.contains(platform.name.toLowerCase())) {
      return _PlatformLegendSort.disconnected;
    }
    return _PlatformLegendSort.neverConnected;
  }

  void _onSectionChanged(int index) {
    if (_section == index) return;
    setState(() {
      _section = index;
      _error = null;
    });
  }

  Widget _buildTabAnimatedTitle() {
    return Text(
      _titleForSection(_section),
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      ),
    );
  }

  Widget _buildTabAnimatedSection() {
    return AnimatedSwitcher(
      duration: _kTabSlideDuration,
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return ClipRect(
          child: Stack(
            alignment: Alignment.topLeft,
            children: <Widget>[
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
        );
      },
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: child,
        );
      },
      child: KeyedSubtree(
        key: ValueKey<int>(_section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildSection(),
        ),
      ),
    );
  }

  void _clearErrorAfterWindow() {
    if (!mounted || _error == null) return;
    setState(() => _error = null);
  }

  void _resetProfileSheetState() {
    _profileNameController.text = _me['fullName']?.toString() ?? '';
    _profileNewEmailController.clear();
    _profileOldEmailOtpController.clear();
    _profileNewEmailOtpController.clear();
    _oldPasswordController.clear();
    _newPasswordController.clear();
    _oldPasswordVerified = false;
    _oldPasswordVisible = false;
    _newPasswordVisible = false;
    _passwordVerifyToken = null;
    _emailChangeFlowId = null;
    _emailOldOtpSent = false;
    _emailOldOtpVerified = false;
    _emailNewOtpSent = false;
  }

  Future<void> _load({bool showLoader = true}) async {
    if (showLoader && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      _api.warmup();
      final meFuture = _api.fetchMe();
      final summaryFuture = _api.fetchSummary();
      final catalogFuture = _api.fetchPlatformCatalog();
      final transactionsFuture = _api.fetchTransactions();
      final contributionsFuture = _api.fetchContributions();
      final insuranceClaimsFuture = _api.fetchInsuranceClaims();
      final loanRequestsFuture = _api.fetchLoanRequests();
      final platformsFuture = _api.fetchUserPlatforms();
      final loanFuture = _api.fetchLoanEligibility();
      final purchasesFuture = _api.fetchSubscriptionPurchases();
      final expensesFuture = _api.fetchExpenses();

      final me = await meFuture;
      final subscriptionFuture = _api.fetchSubscription(me['id'].toString());

      final summary = await summaryFuture;
      final catalog = await catalogFuture;
      _lastCatalogSignature = _catalogSignature(catalog);
      _applyPlatformCatalog(catalog);
      final transactions = await transactionsFuture;
      final contributions = await contributionsFuture;
      final insuranceClaims = await insuranceClaimsFuture;
      final loanRequests = await loanRequestsFuture;
      final platforms = await platformsFuture;
      _syncIntegrationFlags(platforms);
      final loan = await loanFuture;
      final subscription = await subscriptionFuture;
      await _notifyPlanExpiryNotifications(subscription);
      final purchases = await purchasesFuture;
      var expenses = await expensesFuture;

      bool hasTodayKind(List<dynamic> list, String kind) {
        final nowIst = _toIst(DateTime.now());
        final today = DateTime(nowIst.year, nowIst.month, nowIst.day);
        for (final e in list) {
          final createdRaw = e['created_at'] ?? e['createdAt'];
          if (createdRaw == null) continue;
          final dt = DateTime.tryParse(createdRaw.toString());
          if (dt == null) continue;
          final ist = _toIst(dt);
          final day = DateTime(ist.year, ist.month, ist.day);
          if (day != today) continue;

          final cat = (e['category'] ?? '').toString().toLowerCase();
          final note = (e['note'] ?? '').toString().toLowerCase();
          if (kind == 'fuel') {
            if (cat.contains('fuel') ||
                cat.contains('petrol') ||
                cat.contains('diesel') ||
                note.contains('fuel') ||
                note.contains('petrol') ||
                note.contains('diesel')) {
              return true;
            }
          } else if (kind == 'rent') {
            if (cat.contains('rent') ||
                cat.contains('rental') ||
                cat.contains('vehicle') ||
                note.contains('rent') ||
                note.contains('rental') ||
                note.contains('vehicle')) {
              return true;
            }
          }
        }
        return false;
      }

      final dailyFuel = _toDoubleOrZero(me['dailyFuel'] ?? me['daily_fuel']);
      final dailyRent = _toDoubleOrZero(me['dailyRent'] ?? me['daily_rent']);
      final vehicleRented = (me['vehicleRented'] == true) ||
          (me['vehicle_rented']?.toString().toLowerCase() == 'true');

      bool expensesChanged = false;
      if (dailyFuel > 0 && !hasTodayKind(expenses, 'fuel')) {
        await _api.upsertDailyExpense(
          category: 'fuel',
          amount: dailyFuel,
          note: 'daily_fuel_auto',
        );
        expensesChanged = true;
      }
      if (vehicleRented && dailyRent > 0 && !hasTodayKind(expenses, 'rent')) {
        await _api.upsertDailyExpense(
          category: 'rent',
          amount: dailyRent,
          note: 'daily_rent_auto',
        );
        expensesChanged = true;
      }
      if (expensesChanged) {
        expenses = await _api.fetchExpenses();
      }

      _profileNameController.text = me['fullName']?.toString() ?? '';

      await _cacheDashboardSnapshot(
        me: me,
        summary: summary,
        loan: loan,
        subscription: subscription,
        transactions: transactions,
        contributions: contributions,
        insuranceClaims: insuranceClaims,
        loanRequests: loanRequests,
        purchases: purchases,
        expenses: expenses,
        catalog: catalog,
        platforms: platforms,
      );

      setState(() {
        _me = me;
        _summary = summary;
        _transactions = transactions;
        _contributions = contributions;
        _insuranceClaims = insuranceClaims;
        _loanRequests = loanRequests;
        _loan = loan;
        _subscription = subscription;
        _subscriptionPurchases = purchases;
        _expenses = expenses;
      });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (showLoader && mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _notifyPlanExpiryNotifications(
      Map<String, dynamic> subscription) async {
    final expired =
        (subscription['recentlyExpiredPlanWindows'] as List?) ?? const [];
    if (expired.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList('plan_expiry_notified_ids_v1')?.toSet() ??
        <String>{};
    bool changed = false;

    for (final item in expired) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item as Map);
      final id = (map['id'] ?? '').toString().trim();
      if (id.isEmpty || seen.contains(id)) continue;

      final plan = (map['plan'] ?? '').toString().trim().toUpperCase();
      await DeviceNotificationService.show(
        id: (id.hashCode & 0x7fffffff),
        title: 'Plan Expired',
        body: plan.isEmpty
            ? 'One of your subscription plans expired. Platform slots from this plan are reset.'
            : '$plan plan expired. Platform slots from this plan are reset.',
      );
      seen.add(id);
      changed = true;
    }

    if (changed) {
      await prefs.setStringList('plan_expiry_notified_ids_v1', seen.toList());
    }
  }

  Future<void> _run(
    Future<void> Function() fn, {
    bool notify = true,
  }) async {
    try {
      await fn();
      await _load(showLoader: false);
      if (mounted && notify) {
        showTopNotification(context, t('done'));
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _addTransaction() async {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || _platformController.text.trim().isEmpty) {
      setState(() => _error = t('enter_valid_platform_amount'));
      return;
    }
    await _run(() async {
      await _api.createTransaction(
        platform: _platformController.text.trim(),
        amount: amount,
      );
      _amountController.clear();
    });
  }

  Future<void> _addExpense() async {
    final amount = double.tryParse(_expenseAmountController.text);
    if (amount == null || _expenseCategoryController.text.trim().isEmpty) {
      setState(() => _error = t('enter_valid_expense'));
      return;
    }
    await _run(() async {
      await _api.addExpense(
        userId: _me['id'].toString(),
        amount: amount,
        category: _expenseCategoryController.text.trim(),
      );
      _expenseAmountController.clear();
    });
  }

  int _randomOtp() => 100000 + math.Random().nextInt(900000);

  String _prettyPlatformName(String raw) {
    final parts = raw
        .trim()
        .split(RegExp(r'[-_\s]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return raw.trim();
    return parts
        .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join(' ');
  }

  Widget _integrationBrandLogo(_IntegrationPlatformState platform,
      {double radius = 12}) {
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
                    size: 22,
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
                              size: 22,
                            ),
                          ))
                    : const SizedBox.shrink()),
            if (!hasNetworkLogo && !hasAssetLogo)
              Center(
                child: Icon(
                  Icons.link,
                  color: platform.brand,
                  size: 22,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _integrationLegendButton({
    required String label,
    required _PlatformLegendSort value,
  }) {
    final selected = _integrationSortPriority == value;
    final baseColor = switch (value) {
      _PlatformLegendSort.connected => const Color(0xFF16C784),
      _PlatformLegendSort.disconnected => const Color(0xFFFFA000),
      _PlatformLegendSort.neverConnected => const Color(0xFF94A3B8),
    };
    final borderColor = baseColor.withValues(alpha: selected ? 0.96 : 0.72);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
        visualDensity: VisualDensity.compact,
        side: BorderSide(
          color: borderColor,
          width: selected ? 1.6 : 1.2,
        ),
        backgroundColor: selected
            ? baseColor.withValues(alpha: 0.12)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () => setState(() => _integrationSortPriority = value),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: selected ? 0.92 : 0.8),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _integrationTile(_IntegrationPlatformState platform) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(18);
    final trips = _platformTripCounts[platform.name.toLowerCase()] ?? 0;
    final earnings =
        _platformTodayEarningsByKey[platform.name.toLowerCase()] ?? 0;
    final activeBoundPlatforms =
        ((_subscription['historyPlatforms'] as List?) ?? const [])
            .map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
    final disconnectedButBound = !platform.verified &&
        activeBoundPlatforms.contains(platform.name.toLowerCase());

    final side = BorderSide(
      color: platform.verified
          ? const Color(0xFF16C784)
          : (disconnectedButBound
              ? const Color(0xFFFFA000)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0x261E3A8A))),
      width: (platform.verified || disconnectedButBound) ? 1.4 : 1,
    );

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: isDark ? 10 : 6,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.18 : 0.10),
      shape: RoundedRectangleBorder(borderRadius: radius, side: side),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _openIntegrationPlatformPopup(platform),
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.transparent,
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.14),
                        ),
                      ),
                      child: _integrationBrandLogo(platform, radius: 14),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      platform.displayName.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 7),
                    if (platform.verified)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '$trips ${t('trips')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF16C784),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              'Rs ${earnings.toStringAsFixed(0)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.85),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Text(
                        t('connect'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
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
            if (platform.verified)
              Positioned(
                right: 2,
                top: 2,
                child: IconButton(
                  tooltip: t('sync_earning'),
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 34, height: 34),
                  padding: EdgeInsets.zero,
                  onPressed: () async {
                    try {
                      final didSync = await _syncOnePlatformRandom(platform);
                      await _load(showLoader: false);
                      if (mounted && didSync) {
                        showTopNotification(
                          context,
                          '${platform.displayName.toUpperCase()} Synced',
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() => _error =
                            e.toString().replaceFirst('Exception: ', ''));
                      }
                    }
                  },
                  icon: Icon(
                    Icons.sync,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openIntegrationPlatformPopup(
      _IntegrationPlatformState platform) async {
    String? modalError;
    bool busy = false;

    await showAnimatedDialog<void>(
      context: context,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (context, setModalState) {
            final activePlan =
                (_subscription['activePlan'] ?? '').toString().trim();
            final historyRaw =
                (_subscription['historyPlatforms'] as List?) ?? const [];
            final history = historyRaw
                .map((e) => e.toString().trim().toLowerCase())
                .where((e) => e.isNotEmpty)
                .toSet();
            final used = int.tryParse((_subscription['used'] ?? '').toString());
            final limit =
                int.tryParse((_subscription['limit'] ?? '').toString());
            final capReached = (limit != null && used != null && used >= limit);
            final platformKey = platform.name.toLowerCase();
            final canConnectThisPlatform = activePlan.isNotEmpty &&
                (!capReached || history.contains(platformKey));

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
                    '${t('invalid_otp_for')} ${_prettyPlatformName(platform.displayName)}');
                return;
              }

              setModalState(() {
                busy = true;
                modalError = null;
              });

              try {
                await _api.connectPlatform(platform: platform.name);
                await _load(showLoader: false);
                if (!dialogContext.mounted) return;

                setState(() {
                  platform.verified = true;
                  platform.otpSent = false;
                  platform.otpController.clear();
                });

                showTopNotification(
                  dialogContext,
                  'Platform Connected: ${_prettyPlatformName(platform.displayName)}',
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

            Future<void> disconnect() async {
              final confirmed = await showAnimatedDialog<bool>(
                    context: dialogContext,
                    builder: (ctx) => AlertDialog(
                      title: Text(_tr3(
                        'Disconnect platform?',
                        'प्लेटफॉर्म डिस्कनेक्ट करें?',
                        'प्लॅटफॉर्म डिस्कनेक्ट करायचा?',
                      )),
                      content: Text(
                        _tr3(
                          'Are you sure you want to disconnect ${platform.displayName.toUpperCase()}?',
                          'क्या आप वाकई ${platform.displayName.toUpperCase()} को डिस्कनेक्ट करना चाहते हैं?',
                          'तुम्हाला नक्की ${platform.displayName.toUpperCase()} डिस्कनेक्ट करायचा आहे का?',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: Text(t('cancel')),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: Text(_tr3(
                            'Disconnect',
                            'डिस्कनेक्ट करें',
                            'डिस्कनेक्ट करा',
                          )),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed) return;

              setModalState(() {
                busy = true;
                modalError = null;
              });
              try {
                await _api.disconnectPlatform(platform: platform.name);
                await _load(showLoader: false);
                if (!dialogContext.mounted) return;

                setState(() {
                  platform.verified = false;
                  platform.otpSent = false;
                  platform.mockOtp = null;
                  platform.otpController.clear();
                });

                showTopNotification(dialogContext,
                    'Platform Disconnected: ${_prettyPlatformName(platform.displayName)}');
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
                        dimension: 26,
                        child: _integrationBrandLogo(platform, radius: 10)),
                  ),
                  const SizedBox(width: 10),
                  Text(platform.displayName.toUpperCase()),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (platform.verified) ...[
                    Text(
                      '${_platformTripCounts[platform.name.toLowerCase()] ?? 0} ${t('trips')}',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: busy ? null : disconnect,
                      child: Text(_tr3(
                          'Disconnect', 'डिस्कनेक्ट करें', 'डिस्कनेक्ट करा')),
                    ),
                  ] else ...[
                    if ((_subscription['activePlan'] ?? '')
                        .toString()
                        .trim()
                        .isEmpty) ...[
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
                    if (activePlan.isNotEmpty &&
                        capReached &&
                        !history.contains(platformKey)) ...[
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
                    if (platform.otpSent) ...[
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
    ).whenComplete(_clearErrorAfterWindow);
  }

  Future<void> _withdraw() async {
    final amount = double.tryParse(_withdrawalController.text);
    if (amount == null || amount < 200) {
      final msg = t('enter_valid_withdrawal');
      setState(() => _error = msg);
      if (mounted) {
        showTopNotification(context, msg, isError: true);
      }
      return;
    }
    try {
      await _api.createWithdrawal(amount: amount);
      await _load(showLoader: false);
      _withdrawalController.clear();
      if (mounted) Navigator.of(context).maybePop();
      if (mounted) {
        showTopNotification(
          context,
          _tr3(
            'Withdrawal successful',
            'निकासी सफल हुई',
            'रक्कम काढणे यशस्वी झाले',
          ),
        );
      }
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() => _error = msg);
        showTopNotification(context, msg, isError: true);
      }
      return;
    }
  }

  String _insuranceTypeLabel(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'vehicle_damage')
      return _tr3('Vehicle Damage', 'वाहन क्षति', 'वाहन नुकसान');
    if (v == 'product_damage_loss') {
      return _tr3(
          'Product Damage/Loss', 'उत्पाद क्षति/हानि', 'उत्पादन नुकसान/हरवणे');
    }
    return raw;
  }

  String _insuranceStatusLabel(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'submitted' || v == 'pending')
      return _tr3('Submitted', 'जमा', 'सबमिट');
    if (v == 'approved') return _tr3('Approved', 'स्वीकृत', 'मंजूर');
    if (v == 'rejected') return _tr3('Rejected', 'अस्वीकृत', 'नाकारले');
    return raw;
  }

  String _loanStatusLabel(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'pending') return _tr3('Pending', 'लंबित', 'प्रलंबित');
    if (v == 'approved') return _tr3('Approved', 'स्वीकृत', 'मंजूर');
    if (v == 'rejected') return _tr3('Rejected', 'अस्वीकृत', 'नाकारले');
    return raw;
  }

  String _dateLabel(dynamic raw) {
    if (raw == null) return '-';
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return raw.toString();
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _ordinalDay(int day) {
    if (day % 100 >= 11 && day % 100 <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  String _formatWithIndianCommas(num value) {
    final s = value.round().toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var head = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (head.length > 2) {
      parts.insert(0, head.substring(head.length - 2));
      head = head.substring(0, head.length - 2);
    }
    if (head.isNotEmpty) parts.insert(0, head);
    return '${parts.join(',')},$last3';
  }

  String _dateTimeLabel(dynamic raw) {
    if (raw == null) return '-';
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return raw.toString();
    final d = dt.toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    final h12 = (d.hour % 12 == 0) ? 12 : (d.hour % 12);
    final hh = h12.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '$dd/$mm/$yyyy $hh:$min $ampm';
  }

  List<dynamic> _latestFirstClaims(List<dynamic> source) {
    final rows = List<dynamic>.from(source);
    rows.sort((a, b) {
      final am =
          a is Map<String, dynamic> ? a : Map<String, dynamic>.from(a as Map);
      final bm =
          b is Map<String, dynamic> ? b : Map<String, dynamic>.from(b as Map);
      final ad = DateTime.tryParse(
              (am['created_at'] ?? am['createdAt'] ?? am['incident_date'] ?? '')
                  .toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bd = DateTime.tryParse(
              (bm['created_at'] ?? bm['createdAt'] ?? bm['incident_date'] ?? '')
                  .toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    return rows;
  }

  Future<void> _refreshLoanAndInsuranceStatuses() async {
    try {
      final results = await Future.wait([
        _api.fetchInsuranceClaims(),
        _api.fetchLoanRequests(),
      ]);
      if (!mounted) return;
      setState(() {
        _insuranceClaims = results[0] as List<dynamic>;
        _loanRequests = results[1] as List<dynamic>;
      });
    } catch (_) {
      // ignore transient sync errors for stream-triggered refresh
    }
  }

  Future<void> _handleApprovalUpdateEvent(Map<String, dynamic> event) async {
    final type = (event['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'hello') return;

    await _refreshLoanAndInsuranceStatuses();
    if (!mounted) return;

    if (type == 'loan_status') {
      final status = _loanStatusLabel((event['status'] ?? '').toString());
      final amount = (event['amount'] ?? 0).toString();
      final message = _tr3(
        'Loan request $status (Rs $amount)',
        'ऋण अनुरोध $status (Rs $amount)',
        'कर्ज विनंती $status (Rs $amount)',
      );
      await DeviceNotificationService.show(
        id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
        title: _tr3('Loan Update', 'ऋण अपडेट', 'कर्ज अपडेट'),
        body: message,
      );
      return;
    }

    if (type == 'insurance_status') {
      final status = _insuranceStatusLabel((event['status'] ?? '').toString());
      final claimType =
          _insuranceTypeLabel((event['claimType'] ?? '').toString());
      final message = _tr3(
        '$claimType claim $status',
        '$claimType दावा $status',
        '$claimType दावा $status',
      );
      await DeviceNotificationService.show(
        id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
        title: _tr3('Insurance Update', 'बीमा अपडेट', 'विमा अपडेट'),
        body: message,
      );
      return;
    }

    if (type == 'account_deletion_status') {
      final status = (event['status'] ?? '').toString().trim().toLowerCase();
      if (status == 'approved') {
        const message =
            'Account deletion approved. Your account will be removed permanently.';
        await DeviceNotificationService.show(
          id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
          title: 'Account Deletion',
          body: message,
        );
        if (!mounted) return;
        // Logout user after approval notification.
        await _logout();
        return;
      }
      if (status == 'rejected') {
        const message = 'Account deletion request was rejected by admin.';
        await DeviceNotificationService.show(
          id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
          title: 'Account Deletion',
          body: message,
        );
      }
    }
  }

  Future<void> _openInsuranceClaimSheet() async {
    String selectedType = 'vehicle_damage';
    DateTime? incidentDate;
    String? proofName;
    String? proofDataUrl;
    String? modalError;
    bool busy = false;

    await showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> pickProof() async {
              try {
                final picked = await FilePicker.platform.pickFiles(
                  allowMultiple: false,
                  withData: true,
                  type: FileType.custom,
                  allowedExtensions: const [
                    'pdf',
                    'jpg',
                    'jpeg',
                    'png',
                    'webp'
                  ],
                );
                if (picked == null || picked.files.isEmpty) return;
                final f = picked.files.first;
                final bytes = f.bytes;
                if (bytes == null || bytes.isEmpty) return;
                const maxBytes = 5 * 1024 * 1024; // 5MB
                if (bytes.length > maxBytes) {
                  setModalState(() {
                    modalError = _tr3(
                      'Proof file too large. Max allowed is 5MB.',
                      'प्रमाण फ़ाइल बहुत बड़ी है। अधिकतम 5MB अनुमति है।',
                      'पुरावा फाइल खूप मोठी आहे. कमाल 5MB अनुमत आहे.',
                    );
                  });
                  return;
                }
                final ext = (f.extension ?? '').toLowerCase();
                final mime = ext == 'pdf'
                    ? 'application/pdf'
                    : (ext == 'png'
                        ? 'image/png'
                        : (ext == 'webp' ? 'image/webp' : 'image/jpeg'));
                final dataUrl =
                    'data:$mime;base64,${base64Encode(Uint8List.fromList(bytes))}';
                setModalState(() {
                  proofName = f.name;
                  proofDataUrl = dataUrl;
                });
              } catch (_) {
                setModalState(() {
                  modalError = _tr3('Failed to pick document',
                      'दस्तावेज़ चुनना विफल', 'दस्तऐवज निवडण्यात अयशस्वी');
                });
              }
            }

            Future<void> submit() async {
              if (incidentDate == null ||
                  proofDataUrl == null ||
                  proofDataUrl!.isEmpty) {
                setModalState(() {
                  modalError = _tr3(
                    'Select insurance type, incident date and proof document',
                    'बीमा प्रकार, घटना तिथि और प्रमाण दस्तावेज़ चुनें',
                    'विमा प्रकार, घटना तारीख आणि पुरावा दस्तऐवज निवडा',
                  );
                });
                return;
              }
              setModalState(() {
                busy = true;
                modalError = null;
              });
              try {
                final d = incidentDate!;
                final incidentDateText =
                    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                await _api.submitClaim(
                  claimType: selectedType,
                  incidentDate: incidentDateText,
                  proofUrl: proofDataUrl!,
                  proofName: proofName,
                );
                await _load(showLoader: false);
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                showTopNotification(
                  this.context,
                  _tr3('Insurance claim applied', 'बीमा दावा जमा हो गया',
                      'विमा दावा सबमिट झाला'),
                );
              } catch (e) {
                setModalState(() {
                  modalError = e.toString().replaceFirst('Exception: ', '');
                });
              } finally {
                if (sheetContext.mounted) setModalState(() => busy = false);
              }
            }

            final bottom = MediaQuery.of(sheetContext).viewInsets.bottom;
            return AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottom),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _tr3('Apply Micro Insurance', 'माइक्रो बीमा लागू करें',
                          'मायक्रो विमा लागू करा'),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _tr3(
                            'Insurance Type', 'बीमा प्रकार', 'विमा प्रकार'),
                      ),
                      selectedItemBuilder: (context) => [
                        Text(
                            _tr3('Vehicle Damage', 'वाहन क्षति', 'वाहन नुकसान'),
                            overflow: TextOverflow.ellipsis),
                        Text(
                            _tr3('Product Damage/Loss', 'उत्पाद क्षति/हानि',
                                'उत्पादन नुकसान/हरवणे'),
                            overflow: TextOverflow.ellipsis),
                      ],
                      items: [
                        DropdownMenuItem(
                          value: 'vehicle_damage',
                          child: Text(
                            _tr3('Vehicle Damage', 'वाहन क्षति', 'वाहन नुकसान'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'product_damage_loss',
                          child: Text(
                            _tr3('Product Damage/Loss', 'उत्पाद क्षति/हानि',
                                'उत्पादन नुकसान/हरवणे'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => setModalState(
                              () => selectedType = v ?? 'vehicle_damage'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final now = DateTime.now();
                              final picked = await showDatePicker(
                                context: sheetContext,
                                initialDate: incidentDate ?? now,
                                firstDate: DateTime(now.year - 2, 1, 1),
                                lastDate: now,
                              );
                              if (picked != null)
                                setModalState(() => incidentDate = picked);
                            },
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        incidentDate == null
                            ? _tr3('Select Incident Date', 'घटना तिथि चुनें',
                                'घटनेची तारीख निवडा')
                            : _dateLabel(incidentDate!.toIso8601String()),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: busy ? null : pickProof,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: Text(
                        proofName == null
                            ? _tr3(
                                'Upload Incident Proof',
                                'घटना प्रमाण अपलोड करें',
                                'घटनेचा पुरावा अपलोड करा')
                            : proofName!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (modalError != null) ...[
                      const SizedBox(height: 10),
                      Text(modalError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w700)),
                    ],
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(busy
                          ? t('please_wait')
                          : _tr3('Submit', 'जमा करें', 'सबमिट')),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openLoanApplySheet() async {
    String? proofName;
    String? proofDataUrl;
    String? modalError;
    String? modalInfo;
    bool busy = false;
    bool submitted = false;
    final amountController = TextEditingController();
    Map<String, num>? estimateFor(double amount) {
      if (amount < 5000 || amount > 50000) return null;
      int months;
      if (amount <= 10000)
        months = 6;
      else if (amount <= 25000)
        months = 12;
      else if (amount <= 40000)
        months = 18;
      else
        months = 24;
      final annualRatePercent =
          (_loan['annualInterestRate'] as num?)?.toDouble() ?? 7.0;
      final annualRate = annualRatePercent / 100.0;
      final monthlyRate = annualRate / 12;
      final pow = math.pow(1 + monthlyRate, months).toDouble();
      final emi = (amount * monthlyRate * pow) / (pow - 1);
      final total = emi * months;
      final interest = total - amount;
      return {'months': months, 'emi': emi, 'interest': interest};
    }

    await showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            Future<void> pickProof() async {
              try {
                final picked = await FilePicker.platform.pickFiles(
                  withData: true,
                  allowMultiple: false,
                  type: FileType.custom,
                  allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
                );
                if (picked == null || picked.files.isEmpty) return;
                final file = picked.files.first;
                final bytes = file.bytes;
                if (bytes == null || bytes.isEmpty) {
                  setModalState(() => modalError = _tr3(
                        'Could not read selected file',
                        'चुनी हुई फ़ाइल पढ़ी नहीं जा सकी',
                        'निवडलेली फाइल वाचता आली नाही',
                      ));
                  return;
                }
                final size = file.size;
                if (size > 5 * 1024 * 1024) {
                  setModalState(() => modalError = _tr3(
                        'File is too large (max 5MB)',
                        'फ़ाइल बहुत बड़ी है (अधिकतम 5MB)',
                        'फाइल खूप मोठी आहे (कमाल 5MB)',
                      ));
                  return;
                }
                final ext = (file.extension ?? '').toLowerCase();
                final mime = ext == 'pdf'
                    ? 'application/pdf'
                    : (ext == 'png' ? 'image/png' : 'image/jpeg');
                proofDataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
                proofName = file.name;
                setModalState(() => modalError = null);
              } catch (_) {
                setModalState(() => modalError = _tr3(
                      'Unable to attach file',
                      'फ़ाइल संलग्न नहीं हो सकी',
                      'फाइल जोडता आली नाही',
                    ));
              }
            }

            Future<void> submit() async {
              final amount = double.tryParse(amountController.text.trim());
              if (amount == null || amount < 5000 || amount > 50000) {
                setModalState(() => modalError = _tr3(
                      'Enter loan amount between Rs 5000 and Rs 50000',
                      'Rs 5000 से Rs 50000 के बीच ऋण राशि दर्ज करें',
                      'Rs 5000 ते Rs 50000 दरम्यान कर्ज रक्कम भरा',
                    ));
                return;
              }
              if (proofDataUrl == null || proofDataUrl!.isEmpty) {
                setModalState(() => modalError = _tr3(
                      'Loan document is required',
                      'ऋण दस्तावेज़ आवश्यक है',
                      'कर्ज दस्तऐवज आवश्यक आहे',
                    ));
                return;
              }
              setModalState(() {
                busy = true;
                modalError = null;
              });
              try {
                final out = await _api.applyLoan(
                  amount: amount,
                  proofUrl: proofDataUrl!,
                  proofName: proofName,
                );
                final emiRaw = out['monthly_installment'] ??
                    out['monthlyInstallment'] ??
                    0;
                final monthsRaw =
                    out['tenure_months'] ?? out['tenureMonths'] ?? 0;
                final interestRaw =
                    out['total_interest'] ?? out['totalInterest'] ?? 0;
                final emi = double.tryParse('$emiRaw') ?? 0;
                final months = int.tryParse('$monthsRaw') ?? 0;
                final interest = double.tryParse('$interestRaw') ?? 0;
                final rate = (double.tryParse(
                            '${out['annual_interest_rate'] ?? out['annualInterestRate'] ?? _loan['annualInterestRate'] ?? 7}') ??
                        7.0)
                    .toStringAsFixed(0);
                setModalState(() {
                  busy = false;
                  submitted = true;
                  modalError = null;
                  modalInfo = _tr3(
                    'Submitted for approval. Rate: $rate% • Tenure: $months months • Interest: Rs ${interest.toStringAsFixed(0)} • Monthly: Rs ${emi.toStringAsFixed(0)}',
                    'अनुमोदन हेतु सबमिट। दर: $rate% • अवधि: $months महीने • ब्याज: Rs ${interest.toStringAsFixed(0)} • मासिक: Rs ${emi.toStringAsFixed(0)}',
                    'मंजुरीसाठी सबमिट. दर: $rate% • कालावधी: $months महिने • व्याज: Rs ${interest.toStringAsFixed(0)} • मासिक: Rs ${emi.toStringAsFixed(0)}',
                  );
                });
                await _load(showLoader: false);
                if (!mounted) return;
                await DeviceNotificationService.show(
                  id: DateTime.now().microsecondsSinceEpoch & 0x7fffffff,
                  title: _tr3('Loan Request', 'ऋण अनुरोध', 'कर्ज विनंती'),
                  body: _tr3(
                    'Loan submitted for approval',
                    'ऋण अनुमोदन के लिए सबमिट हुआ',
                    'कर्ज मंजुरीसाठी सबमिट झाले',
                  ),
                );
              } catch (e) {
                setModalState(() {
                  busy = false;
                  modalError = e.toString().replaceFirst('Exception: ', '');
                });
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(16, 18, 16, 16 + insets),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _tr3('Apply Loan', 'ऋण आवेदन', 'कर्ज अर्ज'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final amount = double.tryParse(v.trim());
                      final est = amount == null ? null : estimateFor(amount);
                      if (submitted) submitted = false;
                      setModalState(() {
                        if (est == null) {
                          modalInfo = null;
                          return;
                        }
                        final rate =
                            (_loan['annualInterestRate'] as num?)?.toDouble() ??
                                7.0;
                        modalInfo = _tr3(
                          'Rate: ${rate.toStringAsFixed(0)}% • Tenure: ${est['months']} months • Interest: Rs ${(est['interest'] as num).toStringAsFixed(0)} • Monthly: Rs ${(est['emi'] as num).toStringAsFixed(0)}',
                          'दर: ${rate.toStringAsFixed(0)}% • अवधि: ${est['months']} महीने • ब्याज: Rs ${(est['interest'] as num).toStringAsFixed(0)} • मासिक: Rs ${(est['emi'] as num).toStringAsFixed(0)}',
                          'दर: ${rate.toStringAsFixed(0)}% • कालावधी: ${est['months']} महिने • व्याज: Rs ${(est['interest'] as num).toStringAsFixed(0)} • मासिक: Rs ${(est['emi'] as num).toStringAsFixed(0)}',
                        );
                      });
                    },
                    decoration: InputDecoration(
                      labelText: _tr3(
                          'Required Amount (Rs 5000 - 50000)',
                          'आवश्यक राशि (Rs 5000 - 50000)',
                          'आवश्यक रक्कम (Rs 5000 - 50000)'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: busy ? null : pickProof,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: Text(
                      proofName == null
                          ? _tr3(
                              'Upload Loan Document',
                              'ऋण दस्तावेज़ अपलोड करें',
                              'कर्ज दस्तऐवज अपलोड करा')
                          : proofName!,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (modalError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      modalError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (modalInfo != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      modalInfo!,
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.86),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : submitted
                            ? () => Navigator.of(dialogContext).pop()
                            : submit,
                    child: Text(
                      busy
                          ? t('please_wait')
                          : submitted
                              ? _tr3('Close', 'बंद करें', 'बंद करा')
                              : _tr3('Submit', 'जमा करें', 'सबमिट'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _purchasePlan(String plan) async {
    await _run(() async {
      await _api.selectSubscription(userId: _me['id'].toString(), plan: plan);
      await _api.confirmSubscription(userId: _me['id'].toString());
    }, notify: false);
    await _load(showLoader: false);
    if (mounted) {
      showTopNotification(
        context,
        '${_tr3('Plan purchased', 'प्लान खरीदा गया', 'प्लॅन खरेदी झाला')}: ${plan.toUpperCase()}',
      );
    }
  }

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
    _activePlansExpanded = false;
    final active = (_subscription['activePlan'] ?? '').toString().toLowerCase();
    String selected = (active == 'solo' ||
            active == 'duo' ||
            active == 'trio' ||
            active == 'unity')
        ? active
        : 'solo';
    String paymentMethod = 'upi';
    String? modalError;
    bool busy = false;

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
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            Future<void> pay() async {
              setModalState(() {
                busy = true;
                modalError = null;
              });
              try {
                await _api.selectSubscription(
                  userId: _me['id'].toString(),
                  plan: selected,
                );
                await _api.confirmSubscription(userId: _me['id'].toString());
                await _load(showLoader: false);
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                showTopNotification(
                  this.context,
                  'Plan Purchased: ${selected.toUpperCase()}',
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
                  ? const Color(0xFF16C784)
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : const Color(0x261E3A8A));
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
                          ? const Color(0xFF16C784)
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.12)
                              : const Color(0x261E3A8A)),
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

            return AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: SafeArea(
                top: true,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final usable = constraints.maxHeight - bottomInset;
                    final height = math.max(
                      320.0,
                      math.min(usable - 24, constraints.maxHeight * 0.82),
                    );

                    return SizedBox(
                      height: height,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          t('subscription_plans'),
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    // Show stacked active windows if available.
                                    if ((_subscription['activePlanWindows']
                                                as List<dynamic>?)
                                            ?.isNotEmpty ==
                                        true) ...[
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surface,
                                          border: Border.all(
                                            color: isDark
                                                ? Colors.white
                                                    .withValues(alpha: 0.10)
                                                : const Color(0x141E3A8A),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  "${t('active_plan')}:",
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const Spacer(),
                                                Text(
                                                  "${_tr3('Platform Limit', 'प्लेटफॉर्म सीमा', 'प्लॅटफॉर्म मर्यादा')}: ${_planLimitLabel()}",
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(
                                                            alpha: 0.78),
                                                  ),
                                                ),
                                                if (((_subscription[
                                                                'activePlanWindows']
                                                            as List<dynamic>)
                                                        .length >
                                                    3))
                                                  InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            12),
                                                    onTap: () {
                                                      setModalState(() {
                                                        _activePlansExpanded =
                                                            !_activePlansExpanded;
                                                      });
                                                    },
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              left: 8),
                                                      child: Icon(
                                                        _activePlansExpanded
                                                            ? Icons
                                                                .keyboard_arrow_up
                                                            : Icons
                                                                .keyboard_arrow_down,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 6),
                                            const SizedBox(height: 2),
                                            AnimatedSize(
                                              duration: const Duration(
                                                  milliseconds: 280),
                                              curve: Curves.easeInOutCubic,
                                              alignment: Alignment.topCenter,
                                              child: Column(
                                                children: (() {
                                                  final all = (_subscription[
                                                          'activePlanWindows']
                                                      as List<dynamic>);
                                                  final visible =
                                                      _activePlansExpanded
                                                          ? all
                                                          : all
                                                              .take(3)
                                                              .toList();
                                                  return visible.map((w) {
                                                    final plan = (w is Map
                                                            ? (w['plan'] ?? '')
                                                            : '')
                                                        .toString();
                                                    final exp = (w is Map
                                                            ? (w['expiresAt'] ??
                                                                '')
                                                            : '')
                                                        .toString();
                                                    return Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              bottom: 8),
                                                      child: Row(
                                                        children: [
                                                          Expanded(
                                                            child: Text(
                                                              plan.toUpperCase(),
                                                              style:
                                                                  const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w900,
                                                                fontSize: 13,
                                                              ),
                                                            ),
                                                          ),
                                                          Text(
                                                            "${t('expires')}: ${_formatIstDateTimeDdMmYyyySafe(exp)}",
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                              fontSize: 12,
                                                              color: Theme.of(
                                                                      context)
                                                                  .colorScheme
                                                                  .onSurface
                                                                  .withValues(
                                                                      alpha:
                                                                          0.72),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                  }).toList();
                                                }()),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ] else if ((_subscription[
                                                'activePlanExpiresAt'] ??
                                            '')
                                        .toString()
                                        .trim()
                                        .isNotEmpty) ...[
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            top: 2, bottom: 10),
                                        child: Text(
                                          "${t('expires')}: ${_formatIstDateTimeDdMmYyyySafe((_subscription['activePlanExpiresAt'] ?? '').toString())}",
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.7),
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 10),
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
                                        payMethod(
                                            'upi', Icons.qr_code_2, t('upi')),
                                        const SizedBox(width: 10),
                                        payMethod('card', Icons.credit_card,
                                            t('card')),
                                        const SizedBox(width: 10),
                                        payMethod('net', Icons.account_balance,
                                            t('net_banking')),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                ),
                              ),
                            ),
                            if (modalError != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  modalError!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
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
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  int _randomInt(int min, int max) {
    return min + math.Random().nextInt(max - min + 1);
  }

  Future<bool> _syncOnePlatformRandom(
      _IntegrationPlatformState platform) async {
    final key = platform.name.toLowerCase();
    final currentToday =
        (_platformTodayEarningsByKey[key] ?? 0).clamp(0.0, 800.0);
    final remaining = (800.0 - currentToday).floor();
    if (remaining < 25) {
      return false;
    }

    // Sometimes no new completed trips are available.
    if (_randomInt(1, 100) <= 30) {
      return false;
    }

    // Generate a valid positive increment that never exceeds per-platform 800 cap.
    int perTrip = _randomInt(25, math.min(50, remaining));
    int maxTrips = math.min(13, remaining ~/ perTrip);
    if (maxTrips < 1) {
      perTrip = 25;
      maxTrips = remaining ~/ perTrip;
      if (maxTrips < 1) {
        return false;
      }
    }
    final trips = _randomInt(1, maxTrips);
    final amount = (trips * perTrip).toDouble();
    await _api.syncPlatformEarning(
      platform: platform.name,
      amount: amount,
      trips: trips,
      perTrip: perTrip.toDouble(),
    );
    return true;
  }

  Future<void> _syncAllConnectedPlatformsRandom({bool notify = true}) async {
    final connected = _integrationPlatforms
        .where((p) => p.verified && p.isAvailable)
        .toList();
    if (connected.isEmpty) {
      if (mounted && notify) {
        showTopNotification(
          context,
          _tr3(
            'No connected platforms',
            'कोई कनेक्टेड प्लेटफॉर्म नहीं है',
            'कोणतेही कनेक्टेड प्लॅटफॉर्म नाहीत',
          ),
        );
      }
      return;
    }
    var syncedAny = false;
    final syncedNames = <String>[];
    for (final p in connected) {
      try {
        final didSync = await _syncOnePlatformRandom(p);
        if (didSync) {
          syncedAny = true;
          syncedNames.add(p.name.toUpperCase());
        }
      } catch (_) {
        // Keep syncing other platforms.
      }
    }
    await _load(showLoader: false);
    if (mounted && syncedAny && notify) {
      if (syncedNames.length == 1) {
        showTopNotification(
          context,
          '${syncedNames.first} ${_tr3('synced', 'सिंक हुआ', 'सिंक झाले')}',
        );
      } else {
        showTopNotification(
          context,
          _tr3(
            'All platforms synced',
            'सभी प्लेटफॉर्म सिंक हो गए',
            'सर्व प्लॅटफॉर्म सिंक झाले',
          ),
        );
      }
    }
  }

  Future<void> _openWithdrawSheet() async {
    _withdrawalController.text = '';
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            18,
            18,
            18 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('withdraw_funds'),
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _withdrawalController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('amount')),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  await _withdraw();
                  if (sheetContext.mounted)
                    Navigator.of(sheetContext).maybePop();
                },
                child: Text(t('withdraw_now')),
              ),
            ],
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  void _openPlatformSyncSheet(_IntegrationPlatformState platform) {
    final amountController = TextEditingController();
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            18,
            18,
            18 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "${platform.displayName.toUpperCase()} ${t('sync_earning')}",
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t('amount')),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  final amount = double.tryParse(amountController.text.trim());
                  if (amount == null || amount <= 0) {
                    showTopNotification(context, t('enter_valid_withdrawal'));
                    return;
                  }
                  await _run(() async {
                    await _api.syncPlatformEarning(
                        platform: platform.name, amount: amount);
                  }, notify: false);
                  if (mounted) {
                    showTopNotification(
                      context,
                      '${platform.displayName.toUpperCase()} Synced',
                    );
                  }
                  if (sheetContext.mounted)
                    Navigator.of(sheetContext).maybePop();
                },
                child: Text(t('sync_earning')),
              ),
            ],
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  Future<void> _optInInsurance() async {
    await _run(() async {
      await _api.optInInsurance();
    }, notify: false);
    if (mounted) {
      showTopNotification(
        context,
        _tr3('Insurance enabled', 'बीमा सक्षम हुआ', 'विमा सक्षम झाले'),
      );
    }
  }

  Future<void> _updateProfile() async {
    if (_profileNameController.text.trim().isEmpty) {
      setState(() => _error = t('name_cannot_empty'));
      return;
    }
    await _run(() async {
      await _api.updateProfile(
        userId: _me['id'].toString(),
        name: _profileNameController.text.trim(),
      );
    });
  }

  Future<void> _requestEmailChange() async {
    if (_profileNewEmailController.text.trim().isEmpty) {
      setState(() => _error = t('new_email_required'));
      return;
    }
    await _run(() async {
      await _api.requestEmailChange(
        currentEmail: _me['email'].toString(),
        newEmail: _profileNewEmailController.text.trim(),
      );
      _profileNewEmailController.clear();
    });
  }

  Future<void> _sendOldEmailOtpForChange({VoidCallback? onUiUpdate}) async {
    try {
      final data = await _api.requestOldEmailOtp();
      _emailChangeFlowId = (data['flowId'] ?? '').toString();
      _emailOldOtpSent =
          _emailChangeFlowId != null && _emailChangeFlowId!.isNotEmpty;
      if (!_emailOldOtpSent) {
        throw Exception(_tr3(
          'Unable to start email verification',
          'ईमेल सत्यापन शुरू नहीं हो सका',
          'ईमेल पडताळणी सुरू करता आली नाही',
        ));
      }
      _emailOldOtpVerified = false;
      _emailNewOtpSent = false;
      _profileOldEmailOtpController.clear();
      _profileNewEmailOtpController.clear();

      if (!mounted) return;
      showTopNotification(
        context,
        _tr3(
          'OTP sent to your email',
          'OTP आपके ईमेल पर भेजा गया',
          'OTP तुमच्या ईमेलवर पाठवला गेला',
        ),
      );
      onUiUpdate?.call();
    } catch (e) {
      if (!mounted) return;
      showTopNotification(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
      onUiUpdate?.call();
    }
  }

  Future<void> _verifyOldEmailOtpAndSendNew({VoidCallback? onUiUpdate}) async {
    final flowId = (_emailChangeFlowId ?? '').trim();
    final otp = _profileOldEmailOtpController.text.trim();
    final newEmail = _profileNewEmailController.text.trim();
    if (flowId.isEmpty ||
        otp.length != 6 ||
        !newEmail.contains('@') ||
        !newEmail.contains('.')) {
      showTopNotification(
        context,
        _tr3('Invalid input', 'अमान्य इनपुट', 'अवैध इनपुट'),
        isError: true,
      );
      return;
    }
    try {
      await _api.verifyOldEmailOtp(
          flowId: flowId, otp: otp, newEmail: newEmail);
      _emailOldOtpVerified = true;
      _emailNewOtpSent = true;

      if (!mounted) return;
      showTopNotification(
        context,
        _tr3(
          'OTP sent to your email',
          'OTP आपके ईमेल पर भेजा गया',
          'OTP तुमच्या ईमेलवर पाठवला गेला',
        ),
      );
      onUiUpdate?.call();
    } catch (e) {
      if (!mounted) return;
      showTopNotification(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
      onUiUpdate?.call();
    }
  }

  Future<void> _verifyNewEmailOtpAndApply({VoidCallback? onUiUpdate}) async {
    final flowId = (_emailChangeFlowId ?? '').trim();
    final otp = _profileNewEmailOtpController.text.trim();
    if (flowId.isEmpty || otp.length != 6) {
      showTopNotification(
        context,
        _tr3('Invalid input', 'अमान्य इनपुट', 'अवैध इनपुट'),
        isError: true,
      );
      return;
    }
    try {
      await _api.verifyNewEmailOtp(flowId: flowId, otp: otp);
      _emailOldOtpSent = false;
      _emailOldOtpVerified = false;
      _emailNewOtpSent = false;
      _emailChangeFlowId = null;
      _profileOldEmailOtpController.clear();
      _profileNewEmailController.clear();
      _profileNewEmailOtpController.clear();

      if (!mounted) return;
      showTopNotification(
        context,
        _tr3('Email changed', 'ईमेल बदल दिया गया', 'ईमेल बदलला गेला'),
      );
      setState(() {});
      onUiUpdate?.call();
    } catch (e) {
      if (!mounted) return;
      showTopNotification(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
      onUiUpdate?.call();
    }
  }

  Future<void> _verifyOldPasswordForChange({VoidCallback? onUiUpdate}) async {
    if (_oldPasswordController.text.isEmpty) {
      showTopNotification(context, t('enter_valid_passwords'), isError: true);
      onUiUpdate?.call();
      return;
    }

    try {
      final data = await _api.verifyOldPassword(
          oldPassword: _oldPasswordController.text);
      final token = (data['verifyToken'] ?? '').toString().trim();
      if (token.isEmpty) {
        throw Exception(_tr3(
          'Old password verification failed',
          'पुराना पासवर्ड सत्यापित नहीं हुआ',
          'जुना पासवर्ड पडताळला गेला नाही',
        ));
      }

      _passwordVerifyToken = token;
      _oldPasswordVerified = true;
      _newPasswordController.clear();

      if (!mounted) return;
      showTopNotification(
        context,
        _tr3(
          'Old password verified',
          'पुराना पासवर्ड सत्यापित हुआ',
          'जुना पासवर्ड पडताळला गेला',
        ),
      );
      onUiUpdate?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _oldPasswordVerified = false;
        _passwordVerifyToken = null;
      });
      showTopNotification(
        context,
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
      onUiUpdate?.call();
    }
  }

  Future<void> _updatePasswordAfterVerification(
      {VoidCallback? onUiUpdate}) async {
    final token = (_passwordVerifyToken ?? '').trim();
    if (token.isEmpty || _newPasswordController.text.length < 8) {
      showTopNotification(context, t('enter_valid_passwords'), isError: true);
      return;
    }
    await _run(() async {
      await _api.updatePasswordWithVerification(
        verifyToken: token,
        newPassword: _newPasswordController.text,
      );
      _oldPasswordVerified = false;
      _passwordVerifyToken = null;
      _oldPasswordController.clear();
      _newPasswordController.clear();
    }, notify: false);
    if (mounted) {
      showTopNotification(
        context,
        _tr3('Password changed', 'पासवर्ड बदल दिया गया', 'पासवर्ड बदलला गेला'),
      );
      setState(() {});
      onUiUpdate?.call();
    }
  }

  Future<void> _changePassword() async {
    if (_oldPasswordController.text.isEmpty ||
        _newPasswordController.text.length < 8) {
      setState(() => _error = t('enter_valid_passwords'));
      return;
    }
    await _run(() async {
      await _api.changePassword(
        email: _me['email'].toString(),
        oldPassword: _oldPasswordController.text,
        newPassword: _newPasswordController.text,
      );
      _oldPasswordController.clear();
      _newPasswordController.clear();
    });
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    widget.onLogout();
  }

  List<Widget> _buildSection() {
    switch (_section) {
      case 0:
        return [
          _walletHeroCard(),
          const SizedBox(height: 14),
          _platformEarningsListCard(),
          const SizedBox(height: 14),
          _expenseTrackerCard(),
          const SizedBox(height: 14),
          _expenseDetailsCard(),
        ];
      case 1:
        return _integrationsSection();
      case 2:
        return _featuresSection();
      case 3:
        return _settingsSection();
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 126),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildTabAnimatedTitle(),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: _tr3('Connected / Limit', 'कनेक्टेड / सीमा',
                            'कनेक्टेड / मर्यादा'),
                        child: TextButton.icon(
                          onPressed: _openSubscriptionSheet,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(36, 40),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(
                            Icons.workspace_premium_outlined,
                            size: 16,
                          ),
                          label: Text(
                            "${_integrationPlatforms.where((p) => p.verified && p.isAvailable).length}/${_integrationPlatforms.where((p) => p.isAvailable).length}",
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      TextButton(
                        onPressed: widget.onCycleLanguage,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(36, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: Text(AppStrings.label(widget.language)),
                      ),
                      IconButton(
                        onPressed: widget.onToggleTheme,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                            width: 42, height: 42),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          widget.isDarkMode
                              ? Icons.wb_sunny
                              : Icons.brightness_2,
                        ),
                      ),
                    ],
                  ),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  const SizedBox(height: 18),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 10),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  _buildTabAnimatedSection(),
                ],
              ),
              _floatingDock(),
              _taxChatbotFloatingButton(constraints),
            ],
          ),
        ),
      ),
    );
  }

  Widget _floatingDock() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: isDark
                  ? const [Color(0xFF1A1530), Color(0xFF241B42)]
                  : const [Color(0xFFFFFFFF), Color(0xFFF6F2FF)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
              if (!isDark)
                const BoxShadow(
                  color: Color(0x441E3A8A),
                  blurRadius: 12,
                  spreadRadius: 0,
                ),
            ],
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0x261E3A8A),
              width: isDark ? 1 : 1.2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BottomNavigationBar(
              currentIndex: _section,
              onTap: _onSectionChanged,
              type: BottomNavigationBarType.fixed,
              backgroundColor: Colors.transparent,
              elevation: 0,
              selectedItemColor: Theme.of(context).colorScheme.primary,
              unselectedItemColor: const Color(0xFF7A7587),
              showSelectedLabels: false,
              showUnselectedLabels: false,
              iconSize: 24,
              selectedFontSize: 0,
              unselectedFontSize: 0,
              selectedIconTheme: const IconThemeData(size: 24),
              unselectedIconTheme: const IconThemeData(size: 24),
              selectedLabelStyle: const TextStyle(fontSize: 0, height: 0),
              unselectedLabelStyle: const TextStyle(fontSize: 0, height: 0),
              items: [
                BottomNavigationBarItem(
                  icon: const Icon(Icons.grid_view_rounded),
                  label: t('dashboard'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.link_rounded),
                  label: t('integrations'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.health_and_safety_outlined),
                  label: t('features'),
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.settings_outlined),
                  label: t('settings'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _taxChatbotFloatingButton(BoxConstraints constraints) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const size = 58.0;
    const minEdge = 8.0;

    final maxLeft = math.max(minEdge, constraints.maxWidth - size - minEdge);
    final maxTop = math.max(minEdge, constraints.maxHeight - size - minEdge);
    final defaultLeft = math.max(minEdge, constraints.maxWidth - size - 16);
    final defaultTop = math.max(minEdge, constraints.maxHeight - size - 102);
    final hasUsableSpace =
        constraints.maxWidth > 180 && constraints.maxHeight > 260;

    if ((_taxFabLeft == null || _taxFabTop == null) && hasUsableSpace) {
      _taxFabLeft = defaultLeft;
      _taxFabTop = defaultTop;
    }

    final left =
        ((_taxFabLeft ?? defaultLeft).clamp(minEdge, maxLeft)).toDouble();
    final top = ((_taxFabTop ?? defaultTop).clamp(minEdge, maxTop)).toDouble();
    if (_taxFabLeft != null && _taxFabTop != null) {
      _taxFabLeft = left;
      _taxFabTop = top;
    }

    // Match the glossy/gradient style from your screenshot.
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [Color(0xFF60E6D5), Color(0xFF16C784), Color(0xFF0F9F7D)]
          : const [Color(0xFF7AF2E4), Color(0xFF16C784), Color(0xFF12A57E)],
      stops: const [0.0, 0.55, 1.0],
    );

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final currentLeft = _taxFabLeft ?? left;
            final currentTop = _taxFabTop ?? top;
            _taxFabLeft = (currentLeft + details.delta.dx)
                .clamp(minEdge, maxLeft)
                .toDouble();
            _taxFabTop = (currentTop + details.delta.dy)
                .clamp(minEdge, maxTop)
                .toDouble();
          });
        },
        child: Material(
          color: Colors.transparent,
          elevation: 16,
          shadowColor: Colors.black.withValues(alpha: isDark ? 0.35 : 0.20),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _openTaxChatbot,
            customBorder: const CircleBorder(),
            child: Ink(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: gradient,
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.22),
                  width: 1.2,
                ),
              ),
              child: Stack(
                children: const [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          center: Alignment(-0.7, -0.8),
                          radius: 0.9,
                          colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Icon(
                      Icons.chat_bubble_outline,
                      color: const Color(0xFF7C3AED),
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _walletHeroCard() {
    final wdUsed =
        int.tryParse((_summary['withdrawalLimitUsed'] ?? '').toString()) ?? 0;
    final wdTotal =
        int.tryParse((_summary['withdrawalLimitTotal'] ?? '').toString()) ?? 0;
    final wdDailyBase =
        int.tryParse((_summary['withdrawalDailyBaseLimit'] ?? '').toString()) ??
            0;
    final wdRemaining =
        int.tryParse((_summary['withdrawalLimitRemaining'] ?? '').toString()) ??
            0;
    final wdRollover = (wdRemaining - wdDailyBase).clamp(0, 1 << 30);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [Color(0xFFFFFFFF), Color(0xFFF4EEFF)],
        ),
        border: Border.all(
          color: const Color(0xFFE0D6FA),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0x331E3A8A),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('total_withdrawable_balance'),
                style: TextStyle(
                  color: const Color(0xFF3A314D),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Rs ${_walletBalance.toStringAsFixed(0)}',
                style: TextStyle(
                  color: const Color(0xFF111111),
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 4),
              RichText(
                text: TextSpan(
                  style: TextStyle(
                    color: const Color(0xFF2F2740),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    height: 1.35,
                  ),
                  children: [
                    TextSpan(
                      text: _tr3(
                        'Monthly Limit: $wdUsed/$wdTotal',
                        'मासिक लिमिट: $wdUsed/$wdTotal',
                        'मासिक मर्यादा: $wdUsed/$wdTotal',
                      ),
                    ),
                    const TextSpan(text: '\n'),
                    TextSpan(
                      text: _tr3(
                        'Daily Limit: $wdRemaining (Base $wdDailyBase + Rollover $wdRollover)',
                        'दैनिक लिमिट: $wdRemaining (बेस $wdDailyBase + रोलओवर $wdRollover)',
                        'दैनिक मर्यादा: $wdRemaining (बेस $wdDailyBase + रोलओव्हर $wdRollover)',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 168,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF19C37D),
                    foregroundColor: const Color(0xFF06261B),
                    textStyle: TextStyle(fontWeight: FontWeight.w800),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _openWithdrawSheet,
                  child: Text(t('withdraw_now')),
                ),
              ),
            ],
          ),
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFFF2ECFF),
                border: Border.all(
                  color: const Color(0xFFD6C7F8),
                ),
              ),
              child: Text(
                '${_totalTrips} ${t('trips')}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  color: const Color(0xFF3C2B63),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: IconButton(
              tooltip: t('sync_earning'),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              onPressed: _syncAllConnectedPlatformsRandom,
              icon: const Icon(Icons.sync, color: Color(0xFF7C3AED)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _platformEarningsListCard() {
    final data = _platformBreakdown;
    if (data.isEmpty) {
      return _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('platform_earnings_breakdown'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 10),
            Text(t('no_platform_data')),
          ],
        ),
      );
    }

    final entries = data.entries.toList();
    final hasMore = entries.length > 2;
    final visible =
        _platformBreakdownExpanded ? entries : entries.take(2).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t('platform_earnings_breakdown'),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasMore)
              IconButton(
                onPressed: () => setState(() =>
                    _platformBreakdownExpanded = !_platformBreakdownExpanded),
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                tooltip: _platformBreakdownExpanded
                    ? _tr3('Collapse', 'समेटें', 'कमी करा')
                    : _tr3('Expand', 'विस्तार करें', 'विस्तार करा'),
                icon: Icon(
                  _platformBreakdownExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                ),
              ),
          ],
        ),
        SizedBox(height: 10),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _settingsListCard([
            for (final entry in visible)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 18,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.10),
                  child: Icon(
                    Icons.storefront,
                    color: Theme.of(context).colorScheme.primary,
                    size: 18,
                  ),
                ),
                title: Text(
                  _prettyPlatformName(entry.key),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  '${_platformTripCounts[entry.key.toLowerCase()] ?? 0} ${t('trips')}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.68),
                  ),
                ),
                trailing: Text(
                  'Rs ${entry.value.toStringAsFixed(0)}',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
          ]),
        ),
      ],
    );
  }

  double _toDoubleOrZero(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  bool _isFuelCategory(String cat, String note) {
    final c = cat.toLowerCase();
    final n = note.toLowerCase();
    return c.contains('fuel') ||
        c.contains('petrol') ||
        c.contains('diesel') ||
        n.contains('fuel') ||
        n.contains('petrol') ||
        n.contains('diesel');
  }

  bool _isRentCategory(String cat, String note) {
    final c = cat.toLowerCase();
    final n = note.toLowerCase();
    return c.contains('rent') ||
        c.contains('rental') ||
        c.contains('vehicle') ||
        n.contains('rent') ||
        n.contains('rental') ||
        n.contains('vehicle');
  }

  List<Map<String, dynamic>> _fuelRentExpensesSorted() {
    final out = <Map<String, dynamic>>[];
    for (final e in _expenses) {
      final createdRaw = (e['created_at'] ?? e['createdAt'])?.toString();
      if (createdRaw == null) continue;
      final created = DateTime.tryParse(createdRaw);
      if (created == null) continue;
      final cat = (e['category'] ?? '').toString();
      final note = (e['note'] ?? '').toString();
      final amount = _toDoubleOrZero(e['amount']);
      if (amount <= 0) continue;

      String? kind;
      if (_isFuelCategory(cat, note)) kind = 'Fuel';
      if (_isRentCategory(cat, note)) kind = 'Rent';
      if (kind == null) continue;

      out.add({
        'kind': kind,
        'amount': amount,
        'createdAt': created,
      });
    }
    out.sort((a, b) =>
        (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime));
    return out;
  }

  Future<void> _downloadExpenseTransactionsPdf() async {
    final rows = _fuelRentExpensesSorted();
    if (rows.isEmpty) {
      if (mounted)
        showTopNotification(
            context,
            _tr3('No expense transactions', 'कोई खर्च लेन-देन नहीं मिला',
                'खर्च व्यवहार आढळले नाहीत'));
      return;
    }

    try {
      final doc = pw.Document();
      final generatedAt =
          _formatIstDateTimeSafe(DateTime.now().toIso8601String());

      doc.addPage(
        pw.MultiPage(
          build: (context) => [
            pw.Text(
              'GigBit Expense Transactions',
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              _tr3(
                'Generated: $generatedAt',
                'जनरेट किया गया: $generatedAt',
                'तयार झाले: $generatedAt',
              ),
            ),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: [
                _tr3('Date', 'तारीख', 'तारीख'),
                _tr3('Type', 'प्रकार', 'प्रकार'),
                _tr3('Amount (Rs)', 'राशि (Rs)', 'रक्कम (Rs)')
              ],
              data: rows
                  .map((e) => [
                        _formatIstDateTimeSafe(
                          (e['createdAt'] as DateTime).toIso8601String(),
                        ),
                        e['kind'].toString(),
                        (e['amount'] as double).toStringAsFixed(0),
                      ])
                  .toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      );

      await Printing.layoutPdf(
        name: 'gigbit_expenses_${DateTime.now().millisecondsSinceEpoch}.pdf',
        onLayout: (format) async => doc.save(),
      );
      if (mounted)
        showTopNotification(context,
            _tr3('PDF downloaded', 'PDF डाउनलोड हुआ', 'PDF डाउनलोड झाले'));
    } catch (e) {
      if (mounted) {
        showTopNotification(
          context,
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  Widget _expenseDetailsCard() {
    final rows = _fuelRentExpensesSorted();
    final hasMore = rows.length > 3;
    final visible = _expenseDetailsExpanded ? rows : rows.take(3).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _tr3('Expense Details', 'खर्च विवरण', 'खर्च तपशील'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
              IconButton(
                tooltip:
                    _tr3('Download PDF', 'PDF डाउनलोड करें', 'PDF डाउनलोड करा'),
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                onPressed: _downloadExpenseTransactionsPdf,
                icon: const Icon(Icons.download_rounded),
              ),
              if (hasMore)
                IconButton(
                  tooltip: _expenseDetailsExpanded
                      ? _tr3('Collapse', 'समेटें', 'कमी करा')
                      : _tr3('Expand', 'विस्तार करें', 'विस्तार करा'),
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  onPressed: () => setState(
                    () => _expenseDetailsExpanded = !_expenseDetailsExpanded,
                  ),
                  icon: Icon(
                    _expenseDetailsExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text(
              _tr3('No expense transactions yet.',
                  'अभी कोई खर्च लेन-देन नहीं है।', 'अजून खर्च व्यवहार नाहीत.'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
            )
          else
            ...visible.map((e) {
              final kind = e['kind'].toString();
              final amount = e['amount'] as double;
              final created = e['createdAt'] as DateTime;
              final dot = kind == 'Fuel'
                  ? const Color(0xFF16C784)
                  : const Color(0xFF1E3A8A);

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: isDark ? 0.30 : 0.92),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : const Color(0x261E3A8A),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: dot,
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$kind • ${_formatIstDateTimeSafe(created.toIso8601String())}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      'Rs ${amount.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  // NOTE: Subscription expense summaries now use IST period boundaries via
  // _subscriptionExpenseSinceIst().

  static const _istOffset = Duration(hours: 5, minutes: 30);

  DateTime _toIst(DateTime dt) => dt.toUtc().add(_istOffset);

  DateTime _userStartDayIst() {
    final raw = (_me['createdAt'] ?? _me['created_at'])?.toString();
    final parsed = raw == null ? null : DateTime.tryParse(raw);
    if (parsed == null) {
      final nowIst = DateTime.now().toUtc().add(_istOffset);
      return DateTime(nowIst.year, nowIst.month, nowIst.day);
    }
    final ist = _toIst(parsed);
    return DateTime(ist.year, ist.month, ist.day);
  }

  String _formatIstDateTimeSafe(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final ist = _toIst(dt);
    final months = [
      _tr3('Jan', 'जन', 'जाने'),
      _tr3('Feb', 'फर', 'फेब्रु'),
      _tr3('Mar', 'मार्च', 'मार्च'),
      _tr3('Apr', 'अप्रै', 'एप्रि'),
      _tr3('May', 'मई', 'मे'),
      _tr3('Jun', 'जून', 'जून'),
      _tr3('Jul', 'जुलाई', 'जुलै'),
      _tr3('Aug', 'अग', 'ऑग'),
      _tr3('Sep', 'सितं', 'सप्टें'),
      _tr3('Oct', 'अक्टू', 'ऑक्टो'),
      _tr3('Nov', 'नवं', 'नोव्हें'),
      _tr3('Dec', 'दिसं', 'डिसें'),
    ];
    final h24 = ist.hour;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 >= 12
        ? _tr3('PM', 'अपराह्न', 'सायं')
        : _tr3('AM', 'पूर्वाह्न', 'सकाळ');
    final mm = ist.minute.toString().padLeft(2, '0');
    final dayLabel = widget.language == AppLanguage.en
        ? _ordinalDay(ist.day)
        : ist.day.toString();
    return '$dayLabel ${months[ist.month - 1]} ${ist.year}, $h12:$mm $ampm';
  }

  String _formatIstDateOnlySafe(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '-';
    final ist = _toIst(dt);
    final dd = ist.day.toString().padLeft(2, '0');
    final mm = ist.month.toString().padLeft(2, '0');
    final yyyy = ist.year.toString();
    return '$dd/$mm/$yyyy';
  }

  String _formatIstDateTimeDdMmYyyySafe(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final ist = _toIst(dt);
    final dd = ist.day.toString().padLeft(2, '0');
    final mm = ist.month.toString().padLeft(2, '0');
    final yyyy = ist.year.toString();
    final h24 = ist.hour;
    final h12 = (h24 % 12 == 0 ? 12 : h24 % 12).toString().padLeft(2, '0');
    final ampm = h24 >= 12
        ? _tr3('PM', 'अपराह्न', 'सायं')
        : _tr3('AM', 'पूर्वाह्न', 'सकाळ');
    final min = ist.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy, $h12:$min $ampm';
  }

  String _dateKeyIst(DateTime ist) {
    final y = ist.year.toString().padLeft(4, '0');
    final m = ist.month.toString().padLeft(2, '0');
    final d = ist.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  DateTime _periodStartIst(String period) {
    final nowIst = DateTime.now().toUtc().add(_istOffset);
    final todayStartIst = DateTime(nowIst.year, nowIst.month, nowIst.day);
    switch (period) {
      case 'weekly':
        // Monday as start of the week.
        return todayStartIst
            .subtract(Duration(days: todayStartIst.weekday - 1));
      case 'monthly':
        return DateTime(nowIst.year, nowIst.month, 1);
      case 'daily':
      default:
        return todayStartIst;
    }
  }

  Map<String, double> _latestExpenseAmountByDateSinceIst(DateTime startIst,
      {required String kind, DateTime? endIst}) {
    final out = <String, double>{};
    final outDt = <String, DateTime>{};

    for (final e in _expenses) {
      final createdRaw = e['created_at'] ?? e['createdAt'];
      if (createdRaw == null) continue;
      final dt = DateTime.tryParse(createdRaw.toString());
      if (dt == null) continue;
      final dtIst = _toIst(dt);
      if (dtIst.isBefore(startIst)) continue;
      if (endIst != null && dtIst.isAfter(endIst)) continue;

      final cat = (e['category'] ?? '').toString().toLowerCase();
      final note = (e['note'] ?? '').toString().toLowerCase();
      final amount = _toDoubleOrZero(e['amount']);

      bool matches = false;
      if (kind == 'fuel') {
        matches = cat.contains('fuel') ||
            note.contains('fuel') ||
            cat.contains('petrol') ||
            cat.contains('diesel');
      } else if (kind == 'rent') {
        matches = cat.contains('rent') ||
            note.contains('rent') ||
            cat.contains('rental') ||
            cat.contains('vehicle');
      }

      if (!matches) continue;

      // Treat the most recent entry for that day as the "edited" amount.
      final k = _dateKeyIst(dtIst);
      final prevDt = outDt[k];
      if (prevDt == null || dtIst.isAfter(prevDt)) {
        outDt[k] = dtIst;
        out[k] = amount;
      }
    }
    return out;
  }

  DateTime _startOfIstDay(DateTime ist) =>
      DateTime(ist.year, ist.month, ist.day);

  DateTime _endOfIstDay(DateTime ist) =>
      DateTime(ist.year, ist.month, ist.day, 23, 59, 59, 999);

  // Subscription series intentionally removed from expense graph per request.

  Map<String, double> _expenseKindByDateIst({
    required DateTime startIst,
    required DateTime endIst,
    required String kind,
    required double perDayDefault,
  }) {
    // Use edited/logged amounts; if today has no edit yet, count today's default once.
    final latest = _latestExpenseAmountByDateSinceIst(
      startIst,
      kind: kind,
      endIst: endIst,
    );
    final out = <String, double>{...latest};

    final nowIst = _toIst(DateTime.now());
    final todayStart = _startOfIstDay(nowIst);
    if (!todayStart.isBefore(_startOfIstDay(startIst)) &&
        !todayStart.isAfter(_startOfIstDay(endIst)) &&
        perDayDefault > 0) {
      final k = _dateKeyIst(todayStart);
      out.putIfAbsent(k, () => perDayDefault);
    }

    return out;
  }

  double _sumMapInRange(
    Map<String, double> m,
    DateTime aIst,
    DateTime bIst,
  ) {
    double sum = 0;
    for (var d = _startOfIstDay(aIst);
        !d.isAfter(_startOfIstDay(bIst));
        d = d.add(const Duration(days: 1))) {
      sum += m[_dateKeyIst(d)] ?? 0;
    }
    return sum;
  }

  Widget _expenseTrackerCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final vehicleRented = (_me['vehicleRented'] == true) ||
        (_me['vehicle_rented']?.toString().toLowerCase() == 'true');
    final dailyFuel = _toDoubleOrZero(_me['dailyFuel'] ?? _me['daily_fuel']);
    final dailyRent = _toDoubleOrZero(_me['dailyRent'] ?? _me['daily_rent']);

    final nowIst = _toIst(DateTime.now());
    final todayStart = _startOfIstDay(nowIst);
    final userStart = _userStartDayIst();

    // All tracker periods are anchored from user registration day.
    final periodStart = userStart.isAfter(todayStart) ? todayStart : userStart;
    final periodEnd = _endOfIstDay(nowIst);

    final fuelByDate = _expenseKindByDateIst(
      startIst: periodStart,
      endIst: periodEnd,
      kind: 'fuel',
      perDayDefault: dailyFuel,
    );
    final rentByDate = vehicleRented
        ? _expenseKindByDateIst(
            startIst: periodStart,
            endIst: periodEnd,
            kind: 'rent',
            perDayDefault: dailyRent,
          )
        : <String, double>{};
    // GigBit subscription removed from graph by request.

    final monthNames = [
      _tr3('Jan', 'जन', 'जाने'),
      _tr3('Feb', 'फर', 'फेब्रु'),
      _tr3('Mar', 'मार्च', 'मार्च'),
      _tr3('Apr', 'अप्रै', 'एप्रि'),
      _tr3('May', 'मई', 'मे'),
      _tr3('Jun', 'जून', 'जून'),
      _tr3('Jul', 'जुलाई', 'जुलै'),
      _tr3('Aug', 'अग', 'ऑग'),
      _tr3('Sep', 'सितं', 'सप्टें'),
      _tr3('Oct', 'अक्टू', 'ऑक्टो'),
      _tr3('Nov', 'नवं', 'नोव्हें'),
      _tr3('Dec', 'दिसं', 'डिसें'),
    ];
    final weekNames = [
      _tr3('Mon', 'सोम', 'सोम'),
      _tr3('Tue', 'मंगल', 'मंगळ'),
      _tr3('Wed', 'बुध', 'बुध'),
      _tr3('Thu', 'गुरु', 'गुरु'),
      _tr3('Fri', 'शुक्र', 'शुक्र'),
      _tr3('Sat', 'शनि', 'शनि'),
      _tr3('Sun', 'रवि', 'रवि'),
    ];

    final buckets = <(String, DateTime, DateTime)>[];
    if (_expensePeriod == 'daily') {
      // Daily dropdown -> each day from registration day to today.
      for (var d = periodStart;
          !d.isAfter(todayStart);
          d = d.add(const Duration(days: 1))) {
        final dayName = weekNames[d.weekday - 1];
        buckets.add(('$dayName ${d.day}', _startOfIstDay(d), _endOfIstDay(d)));
      }
    } else if (_expensePeriod == 'weekly') {
      // Weekly dropdown -> 7-day chunks starting from registration day.
      var s = periodStart;
      while (!s.isAfter(todayStart)) {
        var e = s.add(const Duration(days: 6));
        if (e.isAfter(todayStart)) e = todayStart;
        buckets.add(('${s.day}-${e.day}', _startOfIstDay(s), _endOfIstDay(e)));
        s = e.add(const Duration(days: 1));
      }
    } else if (_expensePeriod == 'monthly') {
      // Monthly dropdown -> month buckets from registration month onward.
      var s = DateTime(periodStart.year, periodStart.month, 1);
      while (!s.isAfter(todayStart)) {
        final e = (s.month == 12)
            ? DateTime(s.year, 12, 31, 23, 59, 59, 999)
            : DateTime(s.year, s.month + 1, 1)
                .subtract(const Duration(milliseconds: 1));
        buckets.add((monthNames[s.month - 1], s, e));
        s = (s.month == 12)
            ? DateTime(s.year + 1, 1, 1)
            : DateTime(s.year, s.month + 1, 1);
      }
    } else {
      for (var d = periodStart;
          !d.isAfter(todayStart);
          d = d.add(const Duration(days: 1))) {
        buckets.add(
            (weekNames[d.weekday - 1], _startOfIstDay(d), _endOfIstDay(d)));
      }
    }

    final bucketValues = buckets.map((b) {
      final start = b.$2.isBefore(periodStart) ? periodStart : b.$2;
      final end = b.$3.isAfter(periodEnd) ? periodEnd : b.$3;
      if (end.isBefore(start)) return (b.$1, 0.0, 0.0);
      final fuel = _sumMapInRange(fuelByDate, start, end);
      final rent = _sumMapInRange(rentByDate, start, end);
      return (b.$1, fuel, rent);
    }).toList();

    final maxVal = bucketValues.fold<double>(0.0, (m, e) {
      final localMax = [e.$2, e.$3].fold<double>(0.0, (a, b) => a > b ? a : b);
      return m > localMax ? m : localMax;
    });

    String periodLabel(String id) {
      switch (id) {
        case 'daily':
          return t('daily');
        case 'weekly':
          return t('weekly');
        case 'monthly':
          return t('monthly');
        default:
          return t('daily');
      }
    }

    Widget periodDropdown() {
      const dropdownWidth = 92.0;
      final border = isDark
          ? Colors.white.withValues(alpha: 0.12)
          : const Color(0x261E3A8A);

      final pillGradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF0E234A), Color(0xFF102B58)]
            : const [Color(0xFFEAF1FF), Color(0xFFFFFFFF)],
      );

      return Container(
        width: dropdownWidth,
        height: 32,
        padding: EdgeInsets.zero,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
          gradient: pillGradient,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.08),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: PopupMenuButton<String>(
          tooltip: _tr3('Period', 'अवधि', 'कालावधी'),
          position: PopupMenuPosition.under,
          popUpAnimationStyle: const AnimationStyle(
            duration: Duration(milliseconds: 260),
            reverseDuration: Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          offset: const Offset(0, 2),
          color: Theme.of(context).colorScheme.surface,
          elevation: 10,
          constraints: const BoxConstraints.tightFor(width: dropdownWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : const Color(0x141E3A8A),
            ),
          ),
          onSelected: (v) => setState(() => _expensePeriod = v),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'daily',
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                t('daily'),
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ),
            PopupMenuItem(
              value: 'weekly',
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                t('weekly'),
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ),
            PopupMenuItem(
              value: 'monthly',
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                t('monthly'),
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                periodLabel(_expensePeriod),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 1),
              Icon(
                Icons.expand_more,
                size: 14,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      );
    }

    Widget tinyBar(double value, Color color) {
      final h = maxVal <= 0 ? 0.08 : (value / maxVal).clamp(0.0, 1.0);
      return AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        height: 6 + (106 * h),
        width: 8,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.95),
              color.withValues(alpha: 0.55),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: isDark ? 0.22 : 0.16),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
          ],
        ),
      );
    }

    Widget bucketGroup(String label, double fuel, double rent) {
      return SizedBox(
        width: 58,
        child: Column(
          children: [
            SizedBox(
              height: 132,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  tinyBar(fuel, const Color(0xFF16C784)),
                  if (vehicleRented) ...[
                    const SizedBox(width: 4),
                    tinyBar(rent, const Color(0xFF1E3A8A)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'F ${fuel.toStringAsFixed(0)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 10,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.76),
              ),
            ),
            if (vehicleRented)
              Text(
                'R ${rent.toStringAsFixed(0)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.76),
                ),
              ),
          ],
        ),
      );
    }

    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _tr3('Tracker', 'ट्रैकर', 'ट्रॅकर'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
              periodDropdown(),
              const SizedBox(width: 6),
              IconButton(
                tooltip: t('edit'),
                onPressed: _openExpenseSettingsSheet,
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: const Color(0xFF16C784),
                      borderRadius: BorderRadius.circular(4))),
              const SizedBox(width: 4),
              Text(_tr3('Fuel', 'ईंधन', 'इंधन'),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              if (vehicleRented) ...[
                const SizedBox(width: 10),
                Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: const Color(0xFF1E3A8A),
                        borderRadius: BorderRadius.circular(4))),
                const SizedBox(width: 4),
                Text(_tr3('Rent', 'किराया', 'भाडे'),
                    style:
                        TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: bucketValues.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final b = bucketValues[i];
                return bucketGroup(b.$1, b.$2, b.$3);
              },
            ),
          ),
          if (!vehicleRented)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _tr3(
                    'Rent is disabled (Vehicle is not rented)',
                    'किराया बंद है (वाहन किराए पर नहीं है)।',
                    'भाडे बंद आहे (वाहन भाड्याने घेतलेले नाही).'),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.65),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openExpenseSettingsSheet() async {
    final rentLocked = (_me['vehicleRented'] == true) ||
        (_me['vehicle_rented']?.toString().toLowerCase() == 'true');
    var vehicleRented = rentLocked;

    _editDailyFuelController.text =
        (_me['dailyFuel'] ?? _me['daily_fuel'] ?? '').toString();
    _editDailyRentController.text =
        (_me['dailyRent'] ?? _me['daily_rent'] ?? '').toString();

    await showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                14,
                16,
                16 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _tr3('Expense Settings', 'खर्च सेटिंग्स', 'खर्च सेटिंग्स'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.10),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('enable_vehicle_rent'),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Switch(
                          value: vehicleRented,
                          onChanged: rentLocked
                              ? null
                              : (v) {
                                  setSheetState(() => vehicleRented = v);
                                  if (!v) _editDailyRentController.clear();
                                },
                        ),
                      ],
                    ),
                  ),
                  if (rentLocked) ...[
                    const SizedBox(height: 8),
                    Text(
                      _tr3(
                        'Vehicle rent is locked and cannot be disabled, raise a complaint to disable it',
                        'वाहन किराया लॉक है और बंद नहीं किया जा सकता, इसे बंद करने के लिए शिकायत दर्ज करें।',
                        'वाहन भाडे लॉक आहे आणि बंद करता येत नाही, ते बंद करण्यासाठी तक्रार नोंदवा.',
                      ),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: _editDailyFuelController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(labelText: t('daily_fuel')),
                  ),
                  const SizedBox(height: 8),
                  if (vehicleRented)
                    TextField(
                      controller: _editDailyRentController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: InputDecoration(labelText: t('rent')),
                    ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: () async {
                      final fuel =
                          double.tryParse(_editDailyFuelController.text.trim());
                      if (fuel == null || !(fuel > 0)) {
                        if (mounted)
                          showTopNotification(context, t('enter_daily_fuel'));
                        return;
                      }

                      final rentText = _editDailyRentController.text.trim();
                      final rent =
                          rentText.isEmpty ? null : double.tryParse(rentText);
                      if (vehicleRented) {
                        if (rent == null || !(rent > 0)) {
                          if (mounted)
                            showTopNotification(context, t('enter_valid_rent'));
                          return;
                        }
                      }

                      try {
                        await _api.updateExpenseSettings(
                          dailyFuel: fuel,
                          vehicleRented: vehicleRented,
                          dailyRent: vehicleRented ? rent : null,
                        );
                        await _api.upsertDailyExpense(
                          category: 'fuel',
                          amount: fuel,
                          note: 'daily_fuel',
                        );
                        if (vehicleRented && rent != null && rent > 0) {
                          await _api.upsertDailyExpense(
                            category: 'rent',
                            amount: rent,
                            note: 'daily_rent',
                          );
                        }
                        await _load(showLoader: false);
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        if (mounted) showTopNotification(context, t('done'));
                      } catch (e) {
                        if (mounted) {
                          showTopNotification(
                            context,
                            e.toString().replaceFirst('Exception: ', ''),
                          );
                        }
                      }
                    },
                    child: Text(_tr3('Save', 'सेव करें', 'सेव्ह करा')),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(t('cancel')),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  List<Widget> _integrationsSection() {
    final activeBoundPlatforms =
        ((_subscription['historyPlatforms'] as List?) ?? const [])
            .map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
    final visiblePlatforms =
        _integrationPlatforms.where((p) => p.isAvailable).toList()
          ..sort((a, b) {
            final an = a.displayName.toLowerCase();
            final bn = b.displayName.toLowerCase();
            final as = _platformLegendStateFor(a, activeBoundPlatforms);
            final bs = _platformLegendStateFor(b, activeBoundPlatforms);

            if (_integrationSortPriority != null) {
              int priority(_PlatformLegendSort s) =>
                  s == _integrationSortPriority ? 0 : 1 + s.index;
              final byPriority = priority(as).compareTo(priority(bs));
              if (byPriority != 0) return byPriority;
            }

            final byState = as.index.compareTo(bs.index);
            if (byState != 0) return byState;
            return an.compareTo(bn);
          });
    final q = _integrationSearchController.text.trim().toLowerCase();
    final filteredPlatforms = q.isEmpty
        ? visiblePlatforms
        : visiblePlatforms
            .where((p) =>
                p.name.toLowerCase().contains(q) ||
                p.displayName.toLowerCase().contains(q))
            .toList();

    return [
      _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('connect_gig_platforms'),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: _tr3(
                      'Search platform', 'प्लेटफॉर्म खोजें', 'प्लॅटफॉर्म शोधा'),
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints.tightFor(width: 36, height: 36),
                  onPressed: () {
                    setState(() {
                      _integrationSearchOpen = !_integrationSearchOpen;
                      if (!_integrationSearchOpen) {
                        _integrationSearchController.clear();
                      }
                    });
                  },
                  icon: Icon(
                    _integrationSearchOpen ? Icons.close : Icons.search,
                    size: 20,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 1,
                  child: _integrationLegendButton(
                    label: _tr3('Connected', 'कनेक्टेड', 'कनेक्टेड'),
                    value: _PlatformLegendSort.connected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _integrationLegendButton(
                    label: _tr3('Disconnected', 'डिस्कनेक्टेड', 'डिस्कनेक्टेड'),
                    value: _PlatformLegendSort.disconnected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: _integrationLegendButton(
                    label: _tr3(
                      'Others',
                      'अन्य',
                      'इतर',
                    ),
                    value: _PlatformLegendSort.neverConnected,
                  ),
                ),
              ],
            ),
            if (_integrationSearchOpen) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _integrationSearchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: _tr3(
                      'Search platform', 'प्लेटफॉर्म खोजें', 'प्लॅटफॉर्म शोधा'),
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
              ),
            ],
            SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final crossAxisCount = w >= 560 ? 4 : (w >= 420 ? 3 : 2);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: NeverScrollableScrollPhysics(),
                  itemCount: filteredPlatforms.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.0,
                  ),
                  itemBuilder: (context, i) =>
                      _integrationTile(filteredPlatforms[i]),
                );
              },
            ),
          ],
        ),
      ),
    ];
  }

  Widget _notInsuredCard() {
    return _glassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('not_insured'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          SizedBox(height: 6),
          Text(
            t('insurance_opt_in_body'),
            style: TextStyle(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.7),
            ),
          ),
          SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
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
              if (ok == true) {
                await _optInInsurance();
              }
            },
            child: Text(t('get_gigbit_insurance')),
          ),
        ],
      ),
    );
  }

  List<Widget> _featuresSection() {
    final activePlan = (_subscription['activePlan'] ?? '').toString().trim();
    if (activePlan.isEmpty) {
      return [
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('subscription_required'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t('plans') + ' ' + t('required_to_continue'),
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.72),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _openSubscriptionSheet,
                icon: const Icon(Icons.workspace_premium_outlined, size: 18),
                label: Text(t('plans')),
              ),
            ],
          ),
        ),
      ];
    }

    return [
      ..._loanSection(),
      const SizedBox(height: 14),
      if (_isInsured) ..._insuranceSection() else _notInsuredCard(),
    ];
  }

  List<Widget> _insuranceSection() {
    final insuranceVisible = _insuranceClaimsExpanded
        ? _latestFirstClaims(_insuranceClaims)
        : _latestFirstClaims(_insuranceClaims).take(1).toList();
    final contributionsSorted = _latestFirstClaims(_contributions);
    final contributionsVisible = _insuranceContributionsExpanded
        ? contributionsSorted
        : contributionsSorted.take(1).toList();
    final contributionTotal = _contributions.fold<double>(
      0,
      (sum, c) {
        final m =
            c is Map<String, dynamic> ? c : Map<String, dynamic>.from(c as Map);
        return sum + _toDouble(m['amount']);
      },
    );
    final claimedTotal = _insuranceClaims.fold<double>(
      0,
      (sum, c) {
        final m =
            c is Map<String, dynamic> ? c : Map<String, dynamic>.from(c as Map);
        final status = (m['status'] ?? '').toString().trim().toLowerCase();
        if (status != 'approved') return sum;
        return sum + _toDouble(m['claim_amount']);
      },
    );
    return [
      _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tr3('Micro Insurance', 'माइक्रो बीमा', 'मायक्रो विमा'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: .2),
                ),
              ),
              child: Text(
                _tr3(
                  'Vehicle Damage: Rs 8000 (max 2 times/year)',
                  'वाहन क्षति: Rs 8000 (वर्ष में अधिकतम 2 बार)',
                  'वाहन नुकसान: Rs 8000 (वर्षातून जास्तीत जास्त 2 वेळा)',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: .2),
                ),
              ),
              child: Text(
                _tr3(
                  'Product Damage/Loss: Rs 3000 (max 3 times/year)',
                  'उत्पाद क्षति/हानि: Rs 3000 (वर्ष में अधिकतम 3 बार)',
                  'उत्पादन नुकसान/हरवणे: Rs 3000 (वर्षातून जास्तीत जास्त 3 वेळा)',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _openInsuranceClaimSheet,
              child: Text(_tr3('Apply', 'Apply', 'Apply')),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr3('My Claims', 'मेरे दावे', 'माझे दावे'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() =>
                      _insuranceClaimsExpanded = !_insuranceClaimsExpanded),
                  tooltip: _insuranceClaimsExpanded
                      ? _tr3('Show less', 'कम दिखाएं', 'कमी दाखवा')
                      : _tr3('Show all', 'सभी दिखाएं', 'सर्व दाखवा'),
                  icon: AnimatedRotation(
                    turns: _insuranceClaimsExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              child: _insuranceClaims.isEmpty
                  ? Text(
                      _tr3(
                          'No claims applied yet',
                          'अभी कोई दावा नहीं किया गया',
                          'अजून कोणताही दावा केलेला नाही'),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : Column(
                      children: insuranceVisible.map((c) {
                        final m = c is Map<String, dynamic>
                            ? c
                            : Map<String, dynamic>.from(c as Map);
                        return ListTile(
                          dense: true,
                          visualDensity:
                              const VisualDensity(horizontal: 0, vertical: -4),
                          minVerticalPadding: 0,
                          contentPadding: EdgeInsets.zero,
                          title: Text(_insuranceTypeLabel(
                              (m['claim_type'] ?? '').toString())),
                          subtitle: Text(_dateTimeLabel(
                              m['incident_date'] ?? m['created_at'])),
                          trailing: Text(
                            _insuranceStatusLabel(
                                (m['status'] ?? '').toString()),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr3('Contributions', 'कॉन्ट्रिब्यूशन्स', 'कॉन्ट्रिब्यूशन्स'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _insuranceContributionsExpanded =
                      !_insuranceContributionsExpanded),
                  tooltip: _insuranceContributionsExpanded
                      ? _tr3('Show less', 'कम दिखाएं', 'कमी दाखवा')
                      : _tr3('Show all', 'सभी दिखाएं', 'सर्व दाखवा'),
                  icon: AnimatedRotation(
                    turns: _insuranceContributionsExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _tr3(
                'Total: Rs ${_formatWithIndianCommas(contributionTotal)}',
                'कुल: Rs ${_formatWithIndianCommas(contributionTotal)}',
                'एकूण: Rs ${_formatWithIndianCommas(contributionTotal)}',
              ),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.84),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _tr3(
                'Claimed: Rs ${_formatWithIndianCommas(claimedTotal)}',
                'क्लेम्ड: Rs ${_formatWithIndianCommas(claimedTotal)}',
                'क्लेम्ड: Rs ${_formatWithIndianCommas(claimedTotal)}',
              ),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.84),
              ),
            ),
            const SizedBox(height: 6),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              child: contributionsVisible.isEmpty
                  ? Text(
                      _tr3(
                        'No contributions yet',
                        'अभी कोई योगदान नहीं है',
                        'अजून कोणतेही योगदान नाही',
                      ),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : Column(
                      children: contributionsVisible.map((c) {
                        final m = c is Map<String, dynamic>
                            ? c
                            : Map<String, dynamic>.from(c as Map);
                        final amountLabel = _tr3(
                          'Amount : Rs ${_formatWithIndianCommas(_toDouble(m['amount']))}',
                          'राशि : Rs ${_formatWithIndianCommas(_toDouble(m['amount']))}',
                          'रक्कम : Rs ${_formatWithIndianCommas(_toDouble(m['amount']))}',
                        );
                        final dtLabel = _dateTimeLabel(m['created_at']);
                        return ListTile(
                          dense: true,
                          visualDensity:
                              const VisualDensity(horizontal: 0, vertical: -4),
                          minVerticalPadding: 0,
                          contentPadding: EdgeInsets.zero,
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  amountLabel,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                dtLabel,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.78),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _loanSection() {
    final eligibility = _loanEligibilityMetrics();
    final score = eligibility['score'] as int? ?? 0;
    final loanVisible = _loanClaimsExpanded
        ? _latestFirstClaims(_loanRequests)
        : _latestFirstClaims(_loanRequests).take(1).toList();
    return [
      _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _tr3('Loans', 'ऋण', 'कर्ज'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _openLoanEligibilityDialog(eligibility),
              icon: const Icon(Icons.rule_folder_outlined, size: 18),
              label: Text(
                _tr3(
                  'Eligibility Score: $score/1000',
                  'पात्रता स्कोर: $score/1000',
                  'पात्रता स्कोअर: $score/1000',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _tr3(
                'Loan Limit: Rs ${_formatWithIndianCommas(_toDoubleOrZero(_loan['limit']))}',
                'ऋण सीमा: Rs ${_formatWithIndianCommas(_toDoubleOrZero(_loan['limit']))}',
                'कर्ज मर्यादा: Rs ${_formatWithIndianCommas(_toDoubleOrZero(_loan['limit']))}',
              ),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
                onPressed: _openLoanApplySheet, child: Text(t('apply_loan'))),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr3('My Claims', 'मेरे दावे', 'माझे दावे'),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                      () => _loanClaimsExpanded = !_loanClaimsExpanded),
                  tooltip: _loanClaimsExpanded
                      ? _tr3('Show less', 'कम दिखाएं', 'कमी दाखवा')
                      : _tr3('Show all', 'सभी दिखाएं', 'सर्व दाखवा'),
                  icon: AnimatedRotation(
                    turns: _loanClaimsExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeInOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              child: _loanRequests.isEmpty
                  ? Text(
                      _tr3(
                        'No loan requests yet',
                        'अभी कोई ऋण अनुरोध नहीं है',
                        'अजून कोणतीही कर्ज विनंती नाही',
                      ),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : Column(
                      children: loanVisible.map((l) {
                        final m = l is Map<String, dynamic>
                            ? l
                            : Map<String, dynamic>.from(l as Map);
                        return ListTile(
                          dense: true,
                          visualDensity:
                              const VisualDensity(horizontal: 0, vertical: -4),
                          minVerticalPadding: 0,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            _tr3(
                              'Claimed : Rs ${m['amount'] ?? 0}',
                              'दावा : Rs ${m['amount'] ?? 0}',
                              'दावा : Rs ${m['amount'] ?? 0}',
                            ),
                          ),
                          subtitle: Text(_dateTimeLabel(m['created_at'])),
                          trailing: Text(
                            _loanStatusLabel((m['status'] ?? '').toString()),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _settingsSection() {
    final fullName = (_me['fullName'] ?? _me['full_name'] ?? _me['name'] ?? '')
        .toString()
        .trim();
    final username = (_me['username'] ?? '').toString().trim();
    final createdAtRaw = _me['createdAt'] ?? _me['created_at'];
    final createdAt = createdAtRaw == null
        ? null
        : DateTime.tryParse(createdAtRaw.toString())?.toLocal();
    final regDate = createdAt == null
        ? '-'
        : '${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.year}';

    return [
      _settingsListCard([
        _settingsItem(
          icon: Icons.badge_outlined,
          title: t('full_name'),
          subtitle: fullName.isEmpty ? '-' : fullName,
          showChevron: false,
        ),
        _settingsItem(
          icon: Icons.alternate_email,
          title: t('username'),
          subtitle: username.isEmpty ? '-' : username,
          showChevron: false,
        ),
        _settingsItem(
          icon: Icons.event_outlined,
          title: _tr3('Registration Date', 'पंजीकरण तिथि', 'नोंदणी तारीख'),
          subtitle: regDate,
          showChevron: false,
        ),
      ]),
      SizedBox(height: 18),
      Text(
        t('your_information'),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
      SizedBox(height: 10),
      _settingsListCard([
        _settingsItem(
          icon: Icons.person_outline,
          title: t('edit_profile'),
          onTap: _openProfileSheet,
        ),
        _settingsItem(
          icon: Icons.history,
          title: t('withdrawal_history'),
          onTap: _openWithdrawalHistorySheet,
        ),
        _settingsItem(
          icon: Icons.workspace_premium_outlined,
          title: _tr3(
            'Subscription History',
            'सब्सक्रिप्शन हिस्ट्री',
            'सब्स्क्रिप्शन इतिहास',
          ),
          onTap: _openSubscriptionHistorySheet,
        ),
        _settingsItem(
          icon: Icons.credit_card,
          title: t('payment_settings'),
          onTap: _openPaymentSettingsSheet,
        ),
        _settingsItem(
          icon: Icons.delete_forever_outlined,
          title: t('delete_account_permanently'),
          subtitle: t('delete_account_subtitle'),
          onTap: _openDeleteAccountSheet,
          isDestructive: true,
        ),
        _settingsItem(
          icon: Icons.logout,
          title: t('logout'),
          onTap: _logout,
          isDestructive: true,
          showChevron: false,
        ),
      ]),
      SizedBox(height: 18),
      Text(
        t('notifications'),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
      SizedBox(height: 10),
      _settingsListCard([
        _settingsItem(
          icon: Icons.notifications_none,
          title: t('notifications'),
          subtitle: 'View all app alerts',
          onTap: _openNotificationsSheet,
        ),
      ]),
      SizedBox(height: 18),
      Text(
        t('legal'),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
      SizedBox(height: 10),
      _settingsListCard([
        _settingsItem(
          icon: Icons.quiz_outlined,
          title: t('faqs'),
          onTap: _openFaqsSheet,
        ),
        _settingsItem(
          icon: Icons.confirmation_number_outlined,
          title: t('raise_ticket'),
          onTap: _openRaiseTicketSheet,
        ),
        _settingsItem(
          icon: Icons.support_agent,
          title: t('help_support'),
          onTap: _openHelpSupportDialog,
        ),
        _settingsItem(
          icon: Icons.description_outlined,
          title: t('terms_conditions'),
          onTap: () => _openLegalSheet(title: t('terms_conditions')),
        ),
        _settingsItem(
          icon: Icons.privacy_tip_outlined,
          title: t('privacy_policy'),
          onTap: () => _openLegalSheet(title: t('privacy_policy')),
        ),
      ]),
    ];
  }

  Widget _settingsListCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.08),
              ),
          ]
        ],
      ),
    );
  }

  Widget _settingsItem({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    bool isDestructive = false,
    bool showChevron = true,
  }) {
    final color = isDestructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(fontWeight: FontWeight.w800, color: color),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
      trailing: showChevron
          ? Icon(Icons.chevron_right,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6))
          : null,
      onTap: onTap,
    );
  }

  void _openDeleteAccountSheet() {
    String selected = 'not_using';
    final deleteOtherReasonController = TextEditingController();
    String? modalError;
    bool busy = false;

    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        Future<void> submit(StateSetter setModalState) async {
          setModalState(() {
            modalError = null;
          });

          final reasonText = selected == 'other'
              ? deleteOtherReasonController.text.trim()
              : null;
          if (selected == 'other' &&
              (reasonText == null || reasonText.isEmpty)) {
            setModalState(() => modalError = t('delete_account_other_reason'));
            return;
          }

          setModalState(() => busy = true);

          try {
            final rootContext = this.context;
            await _api.requestAccountDeletion(
              reasonCode: selected,
              reasonText: reasonText,
            );
            if (!mounted) return;
            if (!context.mounted) return;
            Navigator.of(context).maybePop();
            showTopNotification(rootContext, t('delete_account_submitted'));
          } catch (e) {
            setModalState(() {
              busy = false;
              modalError = e.toString().replaceFirst('Exception: ', '');
            });
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            final h = MediaQuery.of(context).size.height;

            Widget reasonTile({
              required String code,
              required String label,
            }) {
              final active = selected == code;
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => setModalState(() {
                  selected = code;
                  modalError = null;
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: active
                          ? const Color(0xFF16C784)
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.12)
                              : const Color(0x261E3A8A)),
                    ),
                    color: active
                        ? const Color(0xFF16C784)
                            .withValues(alpha: isDark ? 0.10 : 0.08)
                        : Colors.transparent,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        active
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: active
                            ? const Color(0xFF16C784)
                            : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.55),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return SizedBox(
              height: h * 0.66,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('delete_account_permanently'),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: t('cancel'),
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      t('delete_account_subtitle'),
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      t('delete_account_reason'),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView(
                        children: [
                          reasonTile(
                              code: 'privacy', label: t('reason_privacy')),
                          const SizedBox(height: 10),
                          reasonTile(
                              code: 'not_using', label: t('reason_not_using')),
                          const SizedBox(height: 10),
                          reasonTile(
                              code: 'switching', label: t('reason_switching')),
                          const SizedBox(height: 10),
                          reasonTile(
                              code: 'support', label: t('reason_support')),
                          const SizedBox(height: 10),
                          reasonTile(code: 'other', label: t('reason_other')),
                          if (selected == 'other') ...[
                            const SizedBox(height: 10),
                            TextField(
                              controller: deleteOtherReasonController,
                              maxLines: 3,
                              decoration: InputDecoration(
                                labelText: t('delete_account_other_reason'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (modalError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        modalError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : () => submit(setModalState),
                      child: Text(t('delete_account_submit')),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  void _openProfileSheet() {
    _resetProfileSheetState();
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SizedBox(
              height: h * 0.82,
              child: SafeArea(
                top: false,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(14, 12, 14, 14),
                  children: [
                    Text(t('edit_profile'),
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    SizedBox(height: 12),
                    ..._profileSection(onUiUpdate: () => setSheetState(() {})),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  void _openWithdrawalHistorySheet() {
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        var period = 'daily';
        DateTime? selectedMonth;
        int? selectedYear;
        return SizedBox(
          height: h * 0.72,
          child: StatefulBuilder(
            builder: (sheetContext, setModalState) {
              final registrationStart = _userStartDayIst();
              final monthOptions = _historyMonthOptions(registrationStart);
              final yearOptions = _historyYearOptions(registrationStart);
              final theme = Theme.of(sheetContext);
              final scheme = theme.colorScheme;
              final isDark = theme.brightness == Brightness.dark;
              final dropdownTextStyle = TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              );
              final dropdownBg =
                  isDark ? const Color(0xFF13213D) : const Color(0xFFFFFFFF);
              selectedMonth ??=
                  monthOptions.isNotEmpty ? monthOptions.first : null;
              selectedYear ??=
                  yearOptions.isNotEmpty ? yearOptions.first : null;
              return SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t('withdrawal_history'),
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w900),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: period,
                                style: dropdownTextStyle,
                                dropdownColor: dropdownBg,
                                iconEnabledColor: scheme.primary,
                                borderRadius: BorderRadius.circular(12),
                                menuMaxHeight: 320,
                                items: [
                                  DropdownMenuItem(
                                    value: 'daily',
                                    child:
                                        Text(_tr3('Daily', 'दैनिक', 'दैनिक')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'monthly',
                                    child:
                                        Text(_tr3('Monthly', 'मासिक', 'मासिक')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'yearly',
                                    child: Text(
                                        _tr3('Yearly', 'वार्षिक', 'वार्षिक')),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setModalState(() => period = value);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (period == 'monthly')
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _tr3('Month', 'महीना', 'महिना'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<DateTime>(
                                  value: selectedMonth,
                                  style: dropdownTextStyle,
                                  dropdownColor: dropdownBg,
                                  iconEnabledColor: scheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                  menuMaxHeight: 320,
                                  items: monthOptions
                                      .map(
                                        (m) => DropdownMenuItem<DateTime>(
                                          value: m,
                                          child: Text(_monthYearLabel(m)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: monthOptions.isEmpty
                                      ? null
                                      : (value) {
                                          if (value == null) return;
                                          setModalState(
                                              () => selectedMonth = value);
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (period == 'yearly')
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _tr3('Year', 'वर्ष', 'वर्ष'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: selectedYear,
                                  style: dropdownTextStyle,
                                  dropdownColor: dropdownBg,
                                  iconEnabledColor: scheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                  menuMaxHeight: 320,
                                  items: yearOptions
                                      .map(
                                        (y) => DropdownMenuItem<int>(
                                          value: y,
                                          child: Text('$y'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: yearOptions.isEmpty
                                      ? null
                                      : (value) {
                                          if (value == null) return;
                                          setModalState(
                                              () => selectedYear = value);
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (period != 'daily') const SizedBox(height: 8),
                      Expanded(
                        child: FutureBuilder<List<dynamic>>(
                          future: _api.fetchLedger(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            if (snapshot.hasError) {
                              return Center(
                                  child: Text(snapshot.error.toString()));
                            }
                            final ledger = snapshot.data ?? [];
                            final withdrawals = ledger
                                .whereType<Map>()
                                .map((e) => Map<String, dynamic>.from(e))
                                .where((e) =>
                                    (e['entry_type'] ?? e['entryType'] ?? '')
                                        .toString() ==
                                    'withdrawal')
                                .where((e) {
                              final dtIst = _tryParseIstDate(
                                  e['created_at'] ?? e['createdAt']);
                              if (dtIst == null) return false;
                              if (dtIst.isBefore(registrationStart))
                                return false;
                              return _matchesHistoryWindow(
                                dtIst,
                                period,
                                selectedMonth: selectedMonth,
                                selectedYear: selectedYear,
                              );
                            }).toList();
                            if (withdrawals.isEmpty) {
                              return Center(child: Text(t('no_platform_data')));
                            }
                            return ListView.separated(
                              itemCount: withdrawals.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final w = withdrawals[index];
                                final amount = _toDouble(w['amount']);
                                final created =
                                    (w['created_at'] ?? w['createdAt'])
                                            ?.toString() ??
                                        '';
                                return _expenseStyleHistoryCard(
                                  child: Row(
                                    children: [
                                      const Icon(Icons.payments_outlined,
                                          size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          created.isEmpty
                                              ? '-'
                                              : _formatIstDateTimeSafe(created),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        'Rs ${amount.toStringAsFixed(0)}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ).whenComplete(() {
      if (!mounted) return;
      setState(_resetProfileSheetState);
      _clearErrorAfterWindow();
    });
  }

  List<DateTime> _historyMonthOptions(DateTime startDayIst) {
    final nowIst = _toIst(DateTime.now());
    var cursor = DateTime(startDayIst.year, startDayIst.month, 1);
    final end = DateTime(nowIst.year, nowIst.month, 1);
    final out = <DateTime>[];
    while (!cursor.isAfter(end)) {
      out.add(cursor);
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }
    return out.reversed.toList();
  }

  List<int> _historyYearOptions(DateTime startDayIst) {
    final nowIst = _toIst(DateTime.now());
    final out = <int>[];
    for (var y = startDayIst.year; y <= nowIst.year; y++) {
      out.add(y);
    }
    return out.reversed.toList();
  }

  DateTime? _tryParseIstDate(dynamic raw) {
    if (raw == null) return null;
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return null;
    return _toIst(dt);
  }

  String _monthYearLabel(DateTime d) {
    const en = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    const hi = [
      'जनवरी',
      'फ़रवरी',
      'मार्च',
      'अप्रैल',
      'मई',
      'जून',
      'जुलाई',
      'अगस्त',
      'सितंबर',
      'अक्टूबर',
      'नवंबर',
      'दिसंबर'
    ];
    const mr = [
      'जानेवारी',
      'फेब्रुवारी',
      'मार्च',
      'एप्रिल',
      'मे',
      'जून',
      'जुलै',
      'ऑगस्ट',
      'सप्टेंबर',
      'ऑक्टोबर',
      'नोव्हेंबर',
      'डिसेंबर'
    ];
    final name = _tr3(en[d.month - 1], hi[d.month - 1], mr[d.month - 1]);
    return '$name ${d.year}';
  }

  bool _matchesHistoryWindow(
    DateTime dtIst,
    String period, {
    DateTime? selectedMonth,
    int? selectedYear,
  }) {
    if (period == 'monthly') {
      if (selectedMonth == null) return false;
      return dtIst.year == selectedMonth.year &&
          dtIst.month == selectedMonth.month;
    }
    if (period == 'yearly') {
      if (selectedYear == null) return false;
      return dtIst.year == selectedYear;
    }
    return true;
  }

  void _openSubscriptionHistorySheet() {
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        final purchases = _subscriptionPurchases
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        var period = 'daily';
        DateTime? selectedMonth;
        int? selectedYear;
        return SizedBox(
          height: h * 0.72,
          child: StatefulBuilder(
            builder: (sheetContext, setModalState) {
              final registrationStart = _userStartDayIst();
              final monthOptions = _historyMonthOptions(registrationStart);
              final yearOptions = _historyYearOptions(registrationStart);
              final theme = Theme.of(sheetContext);
              final scheme = theme.colorScheme;
              final isDark = theme.brightness == Brightness.dark;
              final dropdownTextStyle = TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              );
              final dropdownBg =
                  isDark ? const Color(0xFF13213D) : const Color(0xFFFFFFFF);
              selectedMonth ??=
                  monthOptions.isNotEmpty ? monthOptions.first : null;
              selectedYear ??=
                  yearOptions.isNotEmpty ? yearOptions.first : null;

              final filtered = purchases.where((p) {
                final dtIst =
                    _tryParseIstDate(p['created_at'] ?? p['createdAt']);
                if (dtIst == null) return false;
                if (dtIst.isBefore(registrationStart)) return false;
                return _matchesHistoryWindow(
                  dtIst,
                  period,
                  selectedMonth: selectedMonth,
                  selectedYear: selectedYear,
                );
              }).toList();

              return SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _tr3(
                                'Subscription History',
                                'सब्सक्रिप्शन हिस्ट्री',
                                'सब्स्क्रिप्शन इतिहास',
                              ),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: period,
                                style: dropdownTextStyle,
                                dropdownColor: dropdownBg,
                                iconEnabledColor: scheme.primary,
                                borderRadius: BorderRadius.circular(12),
                                menuMaxHeight: 320,
                                items: [
                                  DropdownMenuItem(
                                    value: 'daily',
                                    child:
                                        Text(_tr3('Daily', 'दैनिक', 'दैनिक')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'monthly',
                                    child:
                                        Text(_tr3('Monthly', 'मासिक', 'मासिक')),
                                  ),
                                  DropdownMenuItem(
                                    value: 'yearly',
                                    child: Text(
                                        _tr3('Yearly', 'वार्षिक', 'वार्षिक')),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setModalState(() => period = value);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (period == 'monthly')
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _tr3('Month', 'महीना', 'महिना'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<DateTime>(
                                  value: selectedMonth,
                                  style: dropdownTextStyle,
                                  dropdownColor: dropdownBg,
                                  iconEnabledColor: scheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                  menuMaxHeight: 320,
                                  items: monthOptions
                                      .map(
                                        (m) => DropdownMenuItem<DateTime>(
                                          value: m,
                                          child: Text(_monthYearLabel(m)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: monthOptions.isEmpty
                                      ? null
                                      : (value) {
                                          if (value == null) return;
                                          setModalState(
                                              () => selectedMonth = value);
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (period == 'yearly')
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _tr3('Year', 'वर्ष', 'वर्ष'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: selectedYear,
                                  style: dropdownTextStyle,
                                  dropdownColor: dropdownBg,
                                  iconEnabledColor: scheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                  menuMaxHeight: 320,
                                  items: yearOptions
                                      .map(
                                        (y) => DropdownMenuItem<int>(
                                          value: y,
                                          child: Text('$y'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: yearOptions.isEmpty
                                      ? null
                                      : (value) {
                                          if (value == null) return;
                                          setModalState(
                                              () => selectedYear = value);
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (period != 'daily') const SizedBox(height: 8),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  _tr3(
                                    'No plans purchased yet',
                                    'अभी तक कोई प्लान खरीदा नहीं गया',
                                    'अजून कोणताही प्लॅन खरेदी केलेला नाही',
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (context, index) {
                                  final p = filtered[index];
                                  final plan = (p['plan'] ?? '')
                                      .toString()
                                      .toUpperCase();
                                  final from = _formatIstDateOnlySafe(
                                    (p['created_at'] ?? p['createdAt'] ?? '')
                                        .toString(),
                                  );
                                  final to = _formatIstDateOnlySafe(
                                    (p['expires_at'] ?? p['expiresAt'] ?? '')
                                        .toString(),
                                  );
                                  return _expenseStyleHistoryCard(
                                    child: Row(
                                      children: [
                                        const Icon(
                                            Icons.workspace_premium_outlined,
                                            size: 18),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            plan.isEmpty ? '-' : plan,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '$from - $to',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.72),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  Future<void> _openPaymentSettingsSheet() async {
    final prefs = await SharedPreferences.getInstance();
    _upiIdController.text = prefs.getString('payment_upi') ?? '';
    _bankAccountController.text = prefs.getString('payment_account') ?? '';
    _ifscController.text = prefs.getString('payment_ifsc') ?? '';

    if (!mounted) return;
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('payment_settings'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 12),
              TextField(
                controller: _upiIdController,
                decoration: InputDecoration(
                    labelText: _tr3('UPI ID', 'UPI आईडी', 'UPI आयडी')),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _bankAccountController,
                decoration: InputDecoration(
                    labelText: _tr3('Bank Account', 'बैंक खाता', 'बँक खाते')),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _ifscController,
                decoration:
                    InputDecoration(labelText: _tr3('IFSC', 'IFSC', 'IFSC')),
              ),
              SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final upi = _upiIdController.text.trim();
                  final account = _bankAccountController.text.trim();
                  final ifsc = _ifscController.text.trim();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('payment_upi', upi);
                  await prefs.setString('payment_account', account);
                  await prefs.setString('payment_ifsc', ifsc);
                  if (!mounted) return;
                  Navigator.of(this.context).maybePop();
                  showTopNotification(
                      this.context,
                      _tr3('Payment method added', 'भुगतान तरीका जोड़ा गया',
                          'पेमेंट पद्धत जोडली गेली'));
                },
                child: Text(t('update')),
              ),
            ],
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  Future<void> _openNotificationsSheet() async {
    final initial = await NotificationHistoryStore.load();
    if (!mounted) return;

    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        var items = List<Map<String, dynamic>>.from(initial);

        return SizedBox(
          height: h * 0.72,
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t('notifications'),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (items.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                await NotificationHistoryStore.clear();
                                if (!context.mounted) return;
                                setModalState(
                                    () => items = <Map<String, dynamic>>[]);
                              },
                              child: Text(_tr3(
                                  'Clear all', 'सब साफ करें', 'सर्व साफ करा')),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: items.isEmpty
                            ? Center(
                                child: Text(
                                  _tr3(
                                      'No notifications yet',
                                      'अभी कोई नोटिफिकेशन नहीं है',
                                      'अजून कोणतीही सूचना नाही'),
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.70),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  final isError = item['isError'] == true ||
                                      '${item['isError']}'.toLowerCase() ==
                                          'true';
                                  final message =
                                      (item['message'] ?? '').toString();
                                  final createdAt =
                                      (item['createdAt'] ?? '').toString();
                                  final tagRaw =
                                      (item['tag'] ?? '').toString().trim();
                                  final tag = tagRaw.isEmpty
                                      ? NotificationHistoryStore.inferTag(
                                          message,
                                          isError: isError,
                                        )
                                      : tagRaw;
                                  return _expenseStyleHistoryCard(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          isError
                                              ? Icons.error_outline
                                              : Icons
                                                  .notifications_active_outlined,
                                          color: isError
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                  color: isError
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .error
                                                          .withValues(
                                                              alpha: 0.12)
                                                      : Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withValues(
                                                              alpha: 0.14),
                                                ),
                                                child: Text(
                                                  tag,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    fontSize: 11,
                                                    color: isError
                                                        ? Theme.of(context)
                                                            .colorScheme
                                                            .error
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .primary,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                message,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              if (createdAt.isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                  _formatIstDateTimeSafe(
                                                      createdAt),
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(
                                                            alpha: 0.62),
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: _tr3(
                                            'Delete',
                                            'हटाएं',
                                            'हटवा',
                                          ),
                                          visualDensity: VisualDensity.compact,
                                          constraints:
                                              const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                          onPressed: () async {
                                            await NotificationHistoryStore
                                                .deleteAt(index);
                                            if (!context.mounted) return;
                                            setModalState(() {
                                              items.removeAt(index);
                                            });
                                          },
                                          icon:
                                              const Icon(Icons.close, size: 18),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  void _openComingSoon(String title) {
    showAnimatedDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(t('coming_soon')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(_tr3('OK', 'ठीक है', 'ठीक आहे')),
          ),
        ],
      ),
    );
  }

  void _openLegalSheet({required String title}) {
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final h = MediaQuery.of(context).size.height;
        return SizedBox(
          height: h * 0.72,
          child: SafeArea(
            top: false,
            child: ListView(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 14),
              children: [
                Text(title,
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                SizedBox(height: 12),
                _glassCard(
                  child: SelectableText(
                    _legalTextFor(title),
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.82),
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
    ).whenComplete(_clearErrorAfterWindow);
  }

  String _legalTextFor(String title) {
    final k = title.toLowerCase();
    final isTerms =
        k.contains('term') || k.contains('अटी') || k.contains('शर्त');
    if (isTerms) {
      return _tr3(
        [
          'GigBit Terms & Conditions',
          '',
          'GigBit helps gig workers track earnings, expenses, insurance status, and tax assistance across integrated platforms.',
          '',
          'You are responsible for your login credentials, OTP usage, and all actions performed through your account.',
          '',
          'Integrations are user-authorized. GigBit may show synced or estimated data based on available platform linkage.',
          '',
          'Plan purchase determines the maximum number of platforms you can connect, and the limits shown in-app apply.',
          '',
          'GigBit provides productivity and tax-support summaries for convenience. Final filing values must be reviewed by the user before submitting ITR.',
          '',
          'Insurance-related benefits are available only when opted in. Applicable charges are shown in-app and may be auto-deducted as defined.',
          '',
          'Any fraudulent use, unauthorized access, abuse of OTP systems, or manipulation of records can lead to account suspension.',
          '',
          'GigBit does not provide legal or CA representation. Users should consult qualified professionals for legal and tax advice.',
        ].join('\n'),
        [
          'GigBit नियम और शर्तें',
          '',
          '1. प्लेटफॉर्म दायरा',
          'GigBit इंटीग्रेटेड प्लेटफॉर्म पर गिग वर्कर्स को कमाई, खर्च, बीमा स्थिति और टैक्स सहायता ट्रैक करने में मदद करता है।',
          '',
          '2. खाता जिम्मेदारी',
          'आप अपने लॉगिन क्रेडेंशियल, OTP उपयोग और खाते से की गई सभी गतिविधियों के लिए जिम्मेदार हैं।',
          '',
          '3. प्लेटफॉर्म इंटीग्रेशन',
          'इंटीग्रेशन उपयोगकर्ता की अनुमति से होते हैं। उपलब्ध लिंकिंग के आधार पर GigBit सिंक या अनुमानित डेटा दिखा सकता है।',
          '',
          '4. सब्सक्रिप्शन और प्लान सीमा',
          'आपका खरीदा प्लान तय करता है कि अधिकतम कितने प्लेटफॉर्म कनेक्ट कर सकते हैं। वैधता और सीमाएं ऐप में दिखाए अनुसार लागू होती हैं।',
          '',
          '5. कमाई, ट्रिप और टैक्स डेटा',
          'GigBit सुविधा के लिए उत्पादकता और टैक्स सारांश देता है। ITR जमा करने से पहले अंतिम मान उपयोगकर्ता को स्वयं सत्यापित करने होंगे।',
          '',
          '6. बीमा और लाभ',
          'बीमा लाभ केवल ऑप्ट-इन करने पर उपलब्ध हैं। लागू शुल्क ऐप में दिखाए जाते हैं और नियम अनुसार स्वतः कट सकते हैं।',
          '',
          '7. निषिद्ध उपयोग',
          'धोखाधड़ी, अनधिकृत पहुंच, OTP सिस्टम का दुरुपयोग या रिकॉर्ड में छेड़छाड़ पर खाता निलंबित किया जा सकता है।',
          '',
          '8. सीमा',
          'GigBit कानूनी या CA प्रतिनिधित्व प्रदान नहीं करता। कानूनी/टैक्स सलाह के लिए योग्य विशेषज्ञ से परामर्श करें।',
        ].join('\n'),
        [
          'GigBit अटी व शर्ती',
          '',
          '1. प्लॅटफॉर्म व्याप्ती',
          'GigBit इंटीग्रेटेड प्लॅटफॉर्मवर गिग वर्कर्सना कमाई, खर्च, विमा स्थिती आणि टॅक्स सहाय्य ट्रॅक करण्यास मदत करते.',
          '',
          '2. खाते जबाबदारी',
          'तुमचे लॉगिन तपशील, OTP वापर आणि खात्यातून केलेल्या सर्व कृतींसाठी तुम्ही जबाबदार आहात.',
          '',
          '3. प्लॅटफॉर्म इंटीग्रेशन',
          'इंटीग्रेशन वापरकर्त्याच्या परवानगीने होतात. उपलब्ध लिंकिंगनुसार GigBit सिंक/अंदाजित डेटा दाखवू शकते.',
          '',
          '4. सब्स्क्रिप्शन आणि प्लॅन मर्यादा',
          'तुमचा खरेदी केलेला प्लॅन तुम्ही किती प्लॅटफॉर्म जोडू शकता हे ठरवतो. वैधता व मर्यादा अॅपमध्ये दाखवल्याप्रमाणे लागू होतात.',
          '',
          '5. कमाई, ट्रिप्स आणि टॅक्स डेटा',
          'GigBit सोयीसाठी उत्पादकता व टॅक्स सारांश देते. ITR सबमिट करण्यापूर्वी अंतिम मूल्ये वापरकर्त्याने पडताळावी.',
          '',
          '6. विमा आणि फायदे',
          'विमा फायदे फक्त ऑप्ट-इन केल्यावर उपलब्ध असतात. लागू शुल्क अॅपमध्ये दाखवले जातात आणि नियमांनुसार आपोआप वजा होऊ शकतात.',
          '',
          '7. निषिद्ध वापर',
          'फसवणूक, अनधिकृत प्रवेश, OTP प्रणालीचा गैरवापर किंवा नोंदीत छेडछाड केल्यास खाते निलंबित होऊ शकते.',
          '',
          '8. मर्यादा',
          'GigBit कायदेशीर किंवा CA प्रतिनिधित्व देत नाही. कायदेशीर/टॅक्स सल्ल्यासाठी पात्र तज्ज्ञांचा सल्ला घ्या.',
        ].join('\n'),
      );
    }
    return _tr3(
      [
        'GigBit Privacy Policy',
        '',
        '1. Data We Collect',
        'We collect account data (name, username, email), integration metadata, app activity, and support tickets submitted by you.',
        '',
        '2. Why We Use It',
        'Your data is used to provide login access, OTP verification, dashboard analytics, subscription management, and support resolution.',
        '',
        '3. OTP and Security',
        'OTP is used for account verification and sensitive profile updates. We use this to reduce unauthorized access.',
        '',
        '4. Data Sharing',
        'GigBit does not sell personal data. Information may be shared only with required infrastructure/services to operate the platform.',
        '',
        '5. Retention',
        'We retain required records for security, support, and compliance purposes. You can request account deletion from Settings.',
        '',
        '6. User Rights',
        'You may update credentials, raise support requests, and request account deletion subject to verification and compliance checks.',
        '',
        '7. Contact',
        'For privacy concerns, use Raise a Ticket in Settings > Legal.',
      ].join('\n'),
      [
        'GigBit गोपनीयता नीति',
        '',
        '1. हम कौन-सा डेटा लेते हैं',
        'हम खाता डेटा (नाम, यूज़रनेम, ईमेल), इंटीग्रेशन मेटाडेटा, ऐप गतिविधि और आपके सपोर्ट टिकट एकत्र करते हैं।',
        '',
        '2. इसका उपयोग क्यों',
        'आपका डेटा लॉगिन एक्सेस, OTP सत्यापन, डैशबोर्ड एनालिटिक्स, सब्सक्रिप्शन प्रबंधन और सपोर्ट समाधान के लिए उपयोग होता है।',
        '',
        '3. OTP और सुरक्षा',
        'OTP खाता सत्यापन और संवेदनशील प्रोफाइल अपडेट के लिए उपयोग होता है ताकि अनधिकृत पहुंच कम हो।',
        '',
        '4. डेटा साझा करना',
        'GigBit व्यक्तिगत डेटा नहीं बेचता। जानकारी केवल आवश्यक इंफ्रास्ट्रक्चर/सेवाओं के साथ साझा की जा सकती है।',
        '',
        '5. डेटा संग्रह अवधि',
        'सुरक्षा, सपोर्ट और अनुपालन हेतु आवश्यक रिकॉर्ड रखे जाते हैं। आप Settings से अकाउंट डिलीट अनुरोध कर सकते हैं।',
        '',
        '6. उपयोगकर्ता अधिकार',
        'आप क्रेडेंशियल अपडेट, सपोर्ट अनुरोध और सत्यापन/अनुपालन के अधीन अकाउंट डिलीट अनुरोध कर सकते हैं।',
        '',
        '7. संपर्क',
        'गोपनीयता संबंधी चिंता के लिए Settings > Legal > Raise a Ticket का उपयोग करें।',
      ].join('\n'),
      [
        'GigBit गोपनीयता धोरण',
        '',
        '1. आम्ही कोणता डेटा गोळा करतो',
        'आम्ही खाते डेटा (नाव, यूजरनेम, ईमेल), इंटीग्रेशन मेटाडेटा, अॅप अॅक्टिव्हिटी आणि तुम्ही सबमिट केलेले सपोर्ट तिकीट गोळा करतो.',
        '',
        '2. डेटा का वापरतो',
        'तुमचा डेटा लॉगिन, OTP पडताळणी, डॅशबोर्ड विश्लेषण, सब्स्क्रिप्शन व्यवस्थापन आणि सपोर्ट निराकरणासाठी वापरला जातो.',
        '',
        '3. OTP आणि सुरक्षा',
        'OTP खाते पडताळणी व संवेदनशील प्रोफाइल अपडेटसाठी वापरला जातो, ज्यामुळे अनधिकृत प्रवेश कमी होतो.',
        '',
        '4. डेटा शेअरिंग',
        'GigBit वैयक्तिक डेटा विकत नाही. प्लॅटफॉर्म चालवण्यासाठी आवश्यक सेवा/इन्फ्रास्ट्रक्चरपुरतीच माहिती शेअर होऊ शकते.',
        '',
        '5. जतन कालावधी',
        'सुरक्षा, सपोर्ट आणि अनुपालनासाठी आवश्यक नोंदी जतन केल्या जातात. Settings मधून खाते हटवण्याची विनंती करू शकता.',
        '',
        '6. वापरकर्ता हक्क',
        'तुम्ही तपशील अपडेट, सपोर्ट विनंती आणि पडताळणी/अनुपालन अधीन खाते हटवण्याची विनंती करू शकता.',
        '',
        '7. संपर्क',
        'गोपनीयतेसाठी Settings > Legal > Raise a Ticket वापरा.',
      ].join('\n'),
    );
  }

  void _openRaiseTicketSheet() {
    final subjectController = TextEditingController(
      text: _tr3('Support Ticket', 'सपोर्ट टिकट', 'सपोर्ट तिकीट'),
    );
    final complaintController = TextEditingController();
    var busy = false;
    var loadingTickets = true;
    var initialized = false;
    List<dynamic> myTickets = [];
    showAnimatedBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> loadTickets() async {
              try {
                final rows = await _api.fetchSupportTickets(limit: 120);
                if (!sheetContext.mounted) return;
                setSheetState(() {
                  myTickets = rows;
                  loadingTickets = false;
                });
              } catch (_) {
                if (!sheetContext.mounted) return;
                setSheetState(() {
                  myTickets = [];
                  loadingTickets = false;
                });
              }
            }

            if (!initialized) {
              initialized = true;
              Future.microtask(loadTickets);
            }

            String progressLabel(dynamic t) {
              final p =
                  (t['progress'] ?? t['status'] ?? _tr3('Open', 'खुला', 'उघडे'))
                      .toString()
                      .trim();
              if (p.isEmpty) return _tr3('Open', 'खुला', 'उघडे');
              return p;
            }

            Future<void> submit() async {
              final complaint = complaintController.text.trim();
              if (complaint.length < 8) {
                if (mounted)
                  showTopNotification(
                    context,
                    _tr3(
                      'Please enter a valid complaint',
                      'कृपया सही शिकायत दर्ज करें',
                      'कृपया वैध तक्रार नोंदवा',
                    ),
                    isError: true,
                  );
                return;
              }
              setSheetState(() => busy = true);
              try {
                final out = await _api.raiseSupportTicket(
                  subject: subjectController.text.trim(),
                  complaint: complaint,
                );
                final ticket = out['ticket'] is Map<String, dynamic>
                    ? out['ticket'] as Map<String, dynamic>
                    : <String, dynamic>{};
                final ticketNo = (ticket['ticket_number'] ?? '').toString();
                if (mounted) {
                  final msg = ticketNo.isEmpty
                      ? _tr3('Ticket raised', 'टिकट दर्ज किया गया',
                          'तिकीट नोंदवले गेले')
                      : '${_tr3('Ticket submitted', 'टिकट जमा हुआ', 'तिकीट सबमिट झाले')}: $ticketNo';
                  showTopNotification(context, msg);
                }
                complaintController.clear();
                await loadTickets();
              } catch (e) {
                if (mounted) {
                  showTopNotification(
                    context,
                    e.toString().replaceFirst('Exception: ', ''),
                    isError: true,
                  );
                }
              } finally {
                if (sheetContext.mounted) {
                  setSheetState(() => busy = false);
                }
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(sheetContext).size.height * 0.78,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      t('raise_ticket'),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: subjectController,
                      decoration: InputDecoration(
                        labelText: _tr3('Subject', 'विषय', 'विषय'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: complaintController,
                      minLines: 3,
                      maxLines: 5,
                      decoration: InputDecoration(
                        labelText: _tr3('Complaint', 'शिकायत', 'तक्रार'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(busy ? t('please_wait') : t('submit_claim')),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _tr3('My Tickets', 'मेरे टिकट', 'माझी तिकिटे'),
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: loadingTickets
                          ? const Center(child: CircularProgressIndicator())
                          : myTickets.isEmpty
                              ? Center(
                                  child: Text(
                                    _tr3(
                                      'No tickets yet',
                                      'अभी कोई टिकट नहीं है',
                                      'अजून तिकिटे नाहीत',
                                    ),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.65),
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: myTickets.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (context, i) {
                                    final tkt =
                                        myTickets[i] as Map<String, dynamic>;
                                    final ticketNo =
                                        (tkt['ticket_number'] ?? '').toString();
                                    final complaint =
                                        (tkt['complaint'] ?? '').toString();
                                    final subject =
                                        (tkt['subject'] ?? '').toString();
                                    final progress = progressLabel(tkt);
                                    return Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surface,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.10),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  ticketNo.isEmpty
                                                      ? _tr3('Ticket', 'टिकट',
                                                          'तिकीट')
                                                      : ticketNo,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900),
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .secondary
                                                      .withValues(alpha: 0.14),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          999),
                                                ),
                                                child: Text(
                                                  progress,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .secondary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            subject.isEmpty
                                                ? _tr3(
                                                    'Support Ticket',
                                                    'सपोर्ट टिकट',
                                                    'सपोर्ट तिकीट',
                                                  )
                                                : subject,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.85),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            complaint,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.72),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed:
                          busy ? null : () => Navigator.of(sheetContext).pop(),
                      child: Text(t('cancel')),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  void _openHelpSupportDialog() {
    showAnimatedDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('help_support')),
        content: Text(
          _tr3(
            'Email: support@gigbit.app\nWhatsApp: +91 98765 43210\nHelpline: 1800-123-4488\nSupport Hours: 9:00 AM - 8:00 PM (Mon-Sat)',
            'ईमेल: support@gigbit.app\nव्हाट्सऐप: +91 98765 43210\nहेल्पलाइन: 1800-123-4488\nसहायता समय: 9:00 AM - 8:00 PM (सोम-शनि)',
            'ईमेल: support@gigbit.app\nव्हॉट्सअॅप: +91 98765 43210\nहेल्पलाइन: 1800-123-4488\nसपोर्ट वेळ: 9:00 AM - 8:00 PM (सोम-शनि)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(_tr3('OK', 'ठीक है', 'ठीक आहे')),
          ),
        ],
      ),
    );
  }

  void _openFaqsSheet() {
    final faqs = <Map<String, String>>[
      {
        'q': _tr3(
          'What does GigBit do for gig workers?',
          'GigBit गिग वर्कर्स के लिए क्या करता है?',
          'GigBit गिग वर्कर्ससाठी काय करते?',
        ),
        'a': _tr3(
          'GigBit helps you track platform earnings, trips, expenses, subscriptions, and tax-ready summaries in one app.',
          'GigBit आपको एक ही ऐप में प्लेटफॉर्म कमाई, ट्रिप, खर्च, सब्सक्रिप्शन और टैक्स सारांश ट्रैक करने में मदद करता है।',
          'GigBit तुम्हाला एका अॅपमध्ये प्लॅटफॉर्म कमाई, ट्रिप्स, खर्च, सब्स्क्रिप्शन आणि टॅक्स सारांश ट्रॅक करण्यास मदत करते.',
        ),
      },
      {
        'q': _tr3(
          'Which platforms can I connect?',
          'मैं कौन-कौन से प्लेटफॉर्म कनेक्ट कर सकता/सकती हूं?',
          'मी कोणते प्लॅटफॉर्म कनेक्ट करू शकतो/शकते?',
        ),
        'a': _tr3(
          'You can connect supported platforms such as Zomato, Blinkit, Rapido, and Ola based on your active plan limit.',
          'आप अपने सक्रिय प्लान की सीमा के अनुसार समर्थित प्लेटफॉर्म जैसे Zomato, Blinkit, Rapido और Ola कनेक्ट कर सकते हैं।',
          'तुमच्या सक्रिय प्लॅन मर्यादेनुसार तुम्ही Zomato, Blinkit, Rapido आणि Ola सारखे प्लॅटफॉर्म कनेक्ट करू शकता.',
        ),
      },
      {
        'q': _tr3(
          'Why can I not connect more platforms?',
          'मैं अधिक प्लेटफॉर्म क्यों नहीं जोड़ पा रहा/रही?',
          'मी अधिक प्लॅटफॉर्म का जोडू शकत नाही?',
        ),
        'a': _tr3(
          'Platform connections are controlled by your purchased plan slots. Upgrade or buy additional plan capacity to add more platforms.',
          'प्लेटफॉर्म कनेक्शन आपकी खरीदी गई प्लान स्लॉट सीमा से नियंत्रित होते हैं। ज्यादा प्लेटफॉर्म जोड़ने के लिए अपग्रेड करें।',
          'प्लॅटफॉर्म कनेक्शन तुमच्या खरेदी केलेल्या प्लॅन स्लॉटवर अवलंबून असतात. अधिक प्लॅटफॉर्मसाठी अपग्रेड करा.',
        ),
      },
      {
        'q': _tr3(
          'How does sync work?',
          'सिंक कैसे काम करता है?',
          'सिंक कसा काम करतो?',
        ),
        'a': _tr3(
          'When you sync a connected platform, the app updates trip and earning values for that platform and reflects totals in dashboard cards.',
          'कनेक्टेड प्लेटफॉर्म सिंक करने पर ऐप उस प्लेटफॉर्म की ट्रिप और कमाई अपडेट करता है और कुल मान डैशबोर्ड में दिखाता है।',
          'कनेक्टेड प्लॅटफॉर्म सिंक केल्यावर अॅप त्या प्लॅटफॉर्मची ट्रिप व कमाई अपडेट करून एकूण माहिती डॅशबोर्डमध्ये दाखवते.',
        ),
      },
      {
        'q': _tr3(
          'How is withdrawable balance calculated?',
          'निकासी योग्य बैलेंस कैसे निकाला जाता है?',
          'काढण्यायोग्य शिल्लक कशी मोजली जाते?',
        ),
        'a': _tr3(
          'Withdrawable balance is calculated from your synced/recorded platform earnings after applicable deductions and settings.',
          'निकासी योग्य बैलेंस आपकी सिंक/रिकॉर्डेड कमाई से लागू कटौतियों और सेटिंग्स के बाद निकाला जाता है।',
          'काढण्यायोग्य शिल्लक तुमच्या सिंक/नोंदवलेल्या कमाईतून लागू कपातींनंतर मोजली जाते.',
        ),
      },
      {
        'q': _tr3(
          'How does GigBit Insurance work?',
          'GigBit Insurance कैसे काम करता है?',
          'GigBit Insurance कसे काम करते?',
        ),
        'a': _tr3(
          'If enabled, GigBit Insurance activates insurance benefits and auto-deducts the configured monthly amount as per app policy.',
          'सक्षम होने पर GigBit Insurance लाभ सक्रिय होते हैं और नीति के अनुसार मासिक राशि स्वतः कटती है।',
          'सक्षम केल्यावर GigBit Insurance फायदे सक्रिय होतात आणि धोरणानुसार मासिक रक्कम आपोआप वजा होते.',
        ),
      },
      {
        'q': _tr3(
          'How can I file taxes using GigBit?',
          'GigBit से टैक्स फाइल कैसे करूं?',
          'GigBit वापरून टॅक्स फाइल कसा करावा?',
        ),
        'a': _tr3(
          'Use Tax Assistant and expense records to prepare your ITR summary. Always verify final filing values before submitting on the official ITR portal.',
          'Tax Assistant और खर्च रिकॉर्ड से ITR सारांश तैयार करें। आधिकारिक पोर्टल पर जमा करने से पहले अंतिम मान सत्यापित करें।',
          'Tax Assistant आणि खर्च नोंदी वापरून ITR सारांश तयार करा. अधिकृत पोर्टलवर सबमिट करण्यापूर्वी अंतिम मूल्ये पडताळा.',
        ),
      },
      {
        'q': _tr3(
          'How do I raise a complaint?',
          'मैं शिकायत कैसे दर्ज करूं?',
          'मी तक्रार कशी नोंदवू?',
        ),
        'a': _tr3(
          'Go to Settings > Legal > Raise a Ticket, submit your complaint, and track progress in My Tickets with generated ticket ID.',
          'Settings > Legal > Raise a Ticket में जाकर शिकायत दर्ज करें और My Tickets में प्रगति देखें।',
          'Settings > Legal > Raise a Ticket मध्ये जाऊन तक्रार नोंदवा आणि My Tickets मध्ये प्रगती पाहा.',
        ),
      },
      {
        'q': _tr3(
          'Can I change email or password?',
          'क्या मैं ईमेल या पासवर्ड बदल सकता/सकती हूं?',
          'मी ईमेल किंवा पासवर्ड बदलू शकतो/शकते का?',
        ),
        'a': _tr3(
          'Yes. In Edit Profile, password change requires old password verification; email change requires OTP verification on old and new emails.',
          'हाँ। Edit Profile में पासवर्ड बदलने के लिए पुराने पासवर्ड का सत्यापन और ईमेल बदलने के लिए पुराने व नए ईमेल OTP सत्यापन चाहिए।',
          'हो. Edit Profile मध्ये पासवर्ड बदलण्यासाठी जुन्या पासवर्डची पडताळणी आणि ईमेल बदलण्यासाठी जुन्या व नवीन ईमेल OTP पडताळणी आवश्यक आहे.',
        ),
      },
      {
        'q': _tr3(
          'How can I delete my account?',
          'मैं अपना खाता कैसे हटाऊं?',
          'मी माझे खाते कसे हटवू?',
        ),
        'a': _tr3(
          'Use Delete Account in Settings. Your request is submitted for admin approval before final deletion.',
          'Settings में Delete Account का उपयोग करें। अंतिम हटाने से पहले अनुरोध एडमिन अनुमोदन के लिए भेजा जाता है।',
          'Settings मधील Delete Account वापरा. अंतिम हटवण्यापूर्वी विनंती admin मंजुरीसाठी पाठवली जाते.',
        ),
      },
    ];

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
          height: h * 0.66,
          child: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                Text(
                  t('faqs'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                ...faqs.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _glassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item['q'] ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item['a'] ?? '',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.78),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(_clearErrorAfterWindow);
  }

  List<Widget> _profileSection({VoidCallback? onUiUpdate}) {
    return [
      _glassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('change_password'),
                style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            TextField(
              controller: _oldPasswordController,
              obscureText: !_oldPasswordVisible,
              decoration: InputDecoration(
                labelText: t('old_password'),
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() => _oldPasswordVisible = !_oldPasswordVisible);
                    onUiUpdate?.call();
                  },
                  icon: Icon(
                    _oldPasswordVisible
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
            ),
            SizedBox(height: 8),
            if (!_oldPasswordVerified)
              FilledButton(
                onPressed: () =>
                    _verifyOldPasswordForChange(onUiUpdate: onUiUpdate),
                child: Text(
                  _tr3(
                    'Verify Old Password',
                    'पुराना पासवर्ड सत्यापित करें',
                    'जुना पासवर्ड पडताळा',
                  ),
                ),
              ),
            if (_oldPasswordVerified) ...[
              TextField(
                controller: _newPasswordController,
                obscureText: !_newPasswordVisible,
                decoration: InputDecoration(
                  labelText: t('new_password'),
                  suffixIcon: IconButton(
                    onPressed: () {
                      setState(
                          () => _newPasswordVisible = !_newPasswordVisible);
                      onUiUpdate?.call();
                    },
                    icon: Icon(
                      _newPasswordVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 10),
              OutlinedButton(
                onPressed: () =>
                    _updatePasswordAfterVerification(onUiUpdate: onUiUpdate),
                child: Text(t('update_password')),
              ),
            ],
            SizedBox(height: 16),
            Text(
              t('change_email'),
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 10),
            Text(
              '${_tr3('Current', 'वर्तमान', 'सध्याचे')}: ${_me['email'] ?? ''}',
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 10),
            if (!_emailOldOtpSent)
              FilledButton(
                onPressed: () =>
                    _sendOldEmailOtpForChange(onUiUpdate: onUiUpdate),
                child: Text(
                  _tr3(
                    'Send OTP To Old Email',
                    'पुराने ईमेल पर OTP भेजें',
                    'जुन्या ईमेलवर OTP पाठवा',
                  ),
                ),
              ),
            if (_emailOldOtpSent) ...[
              TextField(
                controller: _profileOldEmailOtpController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _tr3(
                    'Old Email OTP',
                    'पुराना ईमेल OTP',
                    'जुन्या ईमेलचा OTP',
                  ),
                ),
              ),
              SizedBox(height: 8),
              TextField(
                controller: _profileNewEmailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: t('new_email')),
              ),
              SizedBox(height: 10),
              if (!_emailOldOtpVerified)
                OutlinedButton(
                  onPressed: () =>
                      _verifyOldEmailOtpAndSendNew(onUiUpdate: onUiUpdate),
                  child: Text(
                    _tr3(
                      'Verify Old OTP & Send New OTP',
                      'पुराना OTP सत्यापित करें और नया OTP भेजें',
                      'जुना OTP पडताळा आणि नवीन OTP पाठवा',
                    ),
                  ),
                ),
            ],
            if (_emailNewOtpSent) ...[
              SizedBox(height: 8),
              TextField(
                controller: _profileNewEmailOtpController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _tr3(
                    'New Email OTP',
                    'नया ईमेल OTP',
                    'नवीन ईमेल OTP',
                  ),
                ),
              ),
              SizedBox(height: 10),
              FilledButton(
                onPressed: () =>
                    _verifyNewEmailOtpAndApply(onUiUpdate: onUiUpdate),
                child: Text(
                  _tr3(
                    'Verify New OTP & Update Email',
                    'नया OTP सत्यापित करें और ईमेल अपडेट करें',
                    'नवीन OTP पडताळा आणि ईमेल अपडेट करा',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  Map<String, dynamic> _loanEligibilityMetrics() {
    if (_loan.isNotEmpty && _loan['score'] != null) {
      return {
        'score': (int.tryParse('${_loan['score']}') ?? 0).clamp(0, 1000),
        'tenureDays': int.tryParse('${_loan['tenureDays'] ?? 0}') ?? 0,
        'monthsWorked':
            (double.tryParse('${_loan['monthsWorked'] ?? 0}') ?? 0.0),
        'consideredDays': int.tryParse('${_loan['consideredDays'] ?? 0}') ?? 0,
        'workedDays': int.tryParse('${_loan['workedDays'] ?? 0}') ?? 0,
        'daysWithMinEarnings':
            int.tryParse('${_loan['daysWithMinEarnings'] ?? 0}') ?? 0,
        'totalEarnings':
            double.tryParse('${_loan['totalEarnings'] ?? 0}') ?? 0.0,
        'avgEarningsPerWorkedDay':
            double.tryParse('${_loan['avgEarningsPerWorkedDay'] ?? 0}') ?? 0.0,
        'met1': _loan['met1'] == true,
        'met2': _loan['met2'] == true,
        'met3': _loan['met3'] == true,
      };
    }

    final nowIst = _toIst(DateTime.now());
    final todayIst = DateTime(nowIst.year, nowIst.month, nowIst.day);
    final userStart = _userStartDayIst();
    final tenureDays = todayIst.difference(userStart).inDays + 1;
    final working90DaysMet = tenureDays >= 90;

    final windowStart = todayIst.subtract(const Duration(days: 89));
    final effectiveStart =
        windowStart.isAfter(userStart) ? windowStart : userStart;
    final consideredDays = todayIst.difference(effectiveStart).inDays + 1;

    final tripsByDay = <String, int>{};
    for (final tx in _transactions) {
      final createdRaw = tx['created_at'] ?? tx['createdAt'];
      if (createdRaw == null) continue;
      final dt = DateTime.tryParse(createdRaw.toString());
      if (dt == null) continue;
      final ist = _toIst(dt);
      final day = DateTime(ist.year, ist.month, ist.day);
      if (day.isBefore(effectiveStart) || day.isAfter(todayIst)) continue;
      final key = _dateKeyIst(day);
      tripsByDay[key] = (tripsByDay[key] ?? 0) + _tripUnitsFromTx(tx);
    }

    final workedDays = tripsByDay.values.where((v) => v > 0).length;
    final earningsByDay = <String, double>{};
    for (final tx in _transactions) {
      final createdRaw = tx['created_at'] ?? tx['createdAt'];
      if (createdRaw == null) continue;
      final dt = DateTime.tryParse(createdRaw.toString());
      if (dt == null) continue;
      final ist = _toIst(dt);
      final day = DateTime(ist.year, ist.month, ist.day);
      if (day.isBefore(effectiveStart) || day.isAfter(todayIst)) continue;
      final key = _dateKeyIst(day);
      earningsByDay[key] = (earningsByDay[key] ?? 0) + _toDouble(tx['amount']);
    }

    final daysWithMinEarnings =
        earningsByDay.values.where((v) => v >= 800).length;
    final totalEarnings =
        earningsByDay.values.fold<double>(0.0, (a, b) => a + b);
    final avgEarningsPerWorkedDay =
        workedDays == 0 ? 0.0 : totalEarnings / workedDays;
    final monthsWorked = tenureDays / 30.0;

    final c1Progress = (tenureDays / 90).clamp(0.0, 1.0);
    final c2Progress = (workedDays / 75).clamp(0.0, 1.0);
    final c3Progress = (daysWithMinEarnings / 75).clamp(0.0, 1.0);
    final score =
        (c1Progress * 300 + c2Progress * 350 + c3Progress * 350).round();

    return {
      'score': score.clamp(0, 1000),
      'tenureDays': tenureDays,
      'monthsWorked': monthsWorked,
      'consideredDays': consideredDays,
      'workedDays': workedDays,
      'daysWithMinEarnings': daysWithMinEarnings,
      'totalEarnings': totalEarnings,
      'avgEarningsPerWorkedDay': avgEarningsPerWorkedDay,
      'met1': working90DaysMet,
      'met2': workedDays >= 75,
      'met3': daysWithMinEarnings >= 75,
    };
  }

  void _openLoanEligibilityDialog(Map<String, dynamic> m) {
    final met1 = m['met1'] == true;
    final met2 = m['met2'] == true;
    final met3 = m['met3'] == true;
    final tenureDays = m['tenureDays'] ?? 0;
    final monthsWorked = (m['monthsWorked'] as num?)?.toDouble() ?? 0.0;
    final consideredDays = m['consideredDays'] ?? 0;
    final workedDays = m['workedDays'] ?? 0;
    final daysWithMinEarnings = m['daysWithMinEarnings'] ?? 0;
    final totalEarnings = (m['totalEarnings'] as num?)?.toDouble() ?? 0.0;
    final avgEarningsPerWorkedDay =
        (m['avgEarningsPerWorkedDay'] as num?)?.toDouble() ?? 0.0;
    final score = (m['score'] as num?)?.toInt() ?? 0;
    final annualInterestRate = (double.tryParse(
            '${_loan['annualInterestRate'] ?? m['annualInterestRate'] ?? 7}') ??
        7.0);
    final minAmount = int.tryParse('${_loan['minAmount'] ?? 5000}') ?? 5000;
    final maxAmount = int.tryParse('${_loan['maxAmount'] ?? 50000}') ?? 50000;

    Widget conditionRow(bool ok, String title, String detail) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.check_circle : Icons.cancel_outlined,
              size: 18,
              color: ok
                  ? const Color(0xFF16C784)
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    detail,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    showAnimatedDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_tr3('Loan Eligibility', 'ऋण पात्रता', 'कर्ज पात्रता')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _tr3('Conditions', 'शर्तें', 'अटी'),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              conditionRow(
                met1,
                _tr3(
                  '1. Must be on platform for at least 90 days',
                  '1. कम से कम 90 दिन प्लेटफॉर्म पर होना चाहिए',
                  '1. किमान 90 दिवस प्लॅटफॉर्मवर असणे आवश्यक',
                ),
                _tr3(
                  'Worked: $tenureDays days',
                  'काम: $tenureDays दिन',
                  'काम: $tenureDays दिवस',
                ),
              ),
              conditionRow(
                met2,
                _tr3(
                  '2. Out of 90 days, must work at least 75 days',
                  '2. 90 दिनों में कम से कम 75 दिन काम होना चाहिए',
                  '2. 90 दिवसांपैकी किमान 75 दिवस काम असावे',
                ),
                _tr3(
                  'Worked days: $workedDays / 75 (window: $consideredDays days)',
                  'काम वाले दिन: $workedDays / 75 (विंडो: $consideredDays दिन)',
                  'कामाचे दिवस: $workedDays / 75 (विंडो: $consideredDays दिवस)',
                ),
              ),
              conditionRow(
                met3,
                _tr3(
                  '3. Out of those 75 days, earnings must be at least Rs 800/day',
                  '3. उन 75 दिनों में कम से कम Rs 800/दिन कमाई होनी चाहिए',
                  '3. त्या 75 दिवसांत दररोज किमान Rs 800 कमाई असावी',
                ),
                _tr3(
                  'Days with >=Rs 800 earnings: $daysWithMinEarnings / 75',
                  '>=Rs 800 कमाई वाले दिन: $daysWithMinEarnings / 75',
                  '>=Rs 800 कमाईचे दिवस: $daysWithMinEarnings / 75',
                ),
              ),
              const SizedBox(height: 6),
              Divider(
                height: 1,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.12),
              ),
              const SizedBox(height: 10),
              Text(
                _tr3('Your Work Summary', 'आपका कार्य सारांश',
                    'तुमचा कामाचा सारांश'),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                _tr3(
                  'Eligibility Score: $score / 1000',
                  'पात्रता स्कोर: $score / 1000',
                  'पात्रता स्कोअर: $score / 1000',
                ),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                _tr3(
                  'Interest Rate: ${annualInterestRate.toStringAsFixed(0)}% (reducing principal)',
                  'ब्याज दर: ${annualInterestRate.toStringAsFixed(0)}% (घटती मूलधन)',
                  'व्याजदर: ${annualInterestRate.toStringAsFixed(0)}% (घटती मूळ रक्कम)',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                _tr3(
                  'Loan Range: Rs $minAmount - Rs $maxAmount',
                  'ऋण सीमा: Rs $minAmount - Rs $maxAmount',
                  'कर्ज रेंज: Rs $minAmount - Rs $maxAmount',
                ),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _tr3(
                  'Months worked: ${monthsWorked.toStringAsFixed(1)}',
                  'किए गए महीने: ${monthsWorked.toStringAsFixed(1)}',
                  'काम केलेले महिने: ${monthsWorked.toStringAsFixed(1)}',
                ),
              ),
              Text(
                _tr3(
                  'Total earnings in considered window: Rs ${totalEarnings.toStringAsFixed(0)}',
                  'विचारित विंडो में कुल कमाई: Rs ${totalEarnings.toStringAsFixed(0)}',
                  'विचारित विंडोतील एकूण कमाई: Rs ${totalEarnings.toStringAsFixed(0)}',
                ),
              ),
              Text(
                _tr3(
                  'Average earnings on worked days: Rs ${avgEarningsPerWorkedDay.toStringAsFixed(0)}',
                  'काम वाले दिनों में औसत कमाई: Rs ${avgEarningsPerWorkedDay.toStringAsFixed(0)}',
                  'कामाच्या दिवसांतील सरासरी कमाई: Rs ${avgEarningsPerWorkedDay.toStringAsFixed(0)}',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).maybePop(),
            child: Text(_tr3('Close', 'बंद करें', 'बंद करा')),
          ),
        ],
      ),
    );
  }

  String _titleForSection(int index) {
    final titles = [
      t('dashboard'),
      t('integrations'),
      t('features'),
      t('settings')
    ];
    return titles[index];
  }

  Widget _glassCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _expenseStyleHistoryCard({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context)
            .colorScheme
            .surface
            .withValues(alpha: isDark ? 0.30 : 0.92),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : const Color(0x261E3A8A),
        ),
      ),
      child: child,
    );
  }
}

