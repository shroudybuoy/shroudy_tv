import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:http/http.dart' as http;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Custom global image caching constraints for intensive logo grids
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20; // 256 MB
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);
  runApp(const ShroudyTvApp());
}

class ShroudyColors {
  static const darkNavyBg = Color(0xFF040F1E);
  static const cardNavyBg = Color(0xFF071B32);
  static const innerLogoBg = Color(0xFF041222);
  static const primaryRed = Color(0xFFEF4444);
  static const accentBorder = Color(0xFF124A78);
  static const liveIndicator = Color(0xFFFF5A5A);
  static const goldText = Color(0xFFFFD700);
}

class ChannelItem {
  final String name;
  final String logoUrl;
  final String streamUrl;
  final String category;
  final String tvgId;

  ChannelItem({
    required this.name,
    required this.logoUrl,
    required this.streamUrl,
    required this.category,
    required this.tvgId,
  });
}

class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;
  final String description;
  final String? imageUrl;

  const EpgProgram({
    required this.start,
    required this.stop,
    required this.title,
    this.description = '',
    this.imageUrl,
  });
}

class EpgData {
  final EpgProgram? now;
  final EpgProgram? next;
  final List<EpgProgram> upcoming;

  const EpgData({
    this.now,
    this.next,
    this.upcoming = const [],
  });
}

class ShroudyTvApp extends StatelessWidget {
  const ShroudyTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shroudy TV ios',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: ShroudyColors.darkNavyBg,
        primaryColor: ShroudyColors.primaryRed,
      ),
      home: const MainDashboard(),
    );
  }
}

class BootSplash extends StatefulWidget {
  const BootSplash({super.key});

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash> with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void dispose() {
    _pulse.dispose();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    final rise = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    final scale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [ShroudyColors.darkNavyBg, ShroudyColors.cardNavyBg],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: fade,
            child: SlideTransition(
              position: rise,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: scale,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [ShroudyColors.primaryRed, Color(0xFFB91C1C)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: ShroudyColors.primaryRed.withAlpha(115),
                            blurRadius: 34,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.live_tv, color: Colors.white, size: 46),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'SHROUDY TV',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'i O S',
                    style: TextStyle(
                      color: Colors.white.withAlpha(150),
                      fontSize: 13,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: 150,
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: Colors.white.withAlpha(30),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        ShroudyColors.primaryRed,
                      ),
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
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  final List<ChannelItem> _allChannelsList = [];
  final List<String> _categoriesList = ['All'];
  final List<String> _favoritesList = [];

  String _selectedCategory = 'All';
  String _searchQuery = '';
  ChannelItem? _currentChannel;
  bool _isLoading = true;
  final Map<String, EpgData> _epgByChannel = {};
  Timer? _epgRefreshTimer;
  String? _playlistEpgUrl;

  final _bootStart = DateTime.now();
  static const Duration _minBootDuration = Duration(milliseconds: 2200);

  bool _isPlayerFullscreen = false;
  final GlobalKey _playerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _fetchM3uPlaylist();
    _epgRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshCurrentEpg());
  }

  Future<void> _finishBoot() async {
    final remaining = _minBootDuration - DateTime.now().difference(_bootStart);
    if (remaining > Duration.zero) await Future.delayed(remaining);
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _fetchM3uPlaylist() async {
    try {
      final response = await http.get(Uri.parse(
        'https://githubusercontent.com',
      ));

      if (response.statusCode == 200) {
        final lines = response.body.split('\n');
        String currentName = '';
        String currentLogo = '';
        String currentCategory = 'Uncategorized';
        String currentTvgId = '';
        final categoriesSet = <String>{};

        for (final raw in lines.take(10)) {
          final header = raw.trim();
          if (header.toUpperCase().startsWith('#EXTM3U')) {
            final declaredEpg = _extractAttribute(header, 'x-tvg-url');
            if (declaredEpg.isNotEmpty) {
              _playlistEpgUrl = declaredEpg;
              break;
            }
          }
        }

        for (var line in lines) {
          final cleanLine = line.trim().replaceAll('\r', '');
          if (cleanLine.isEmpty) continue;

          if (cleanLine.toUpperCase().startsWith('#EXTINF:')) {
            currentName = _extractAttribute(cleanLine, 'tvg-name');
            if (currentName.isEmpty) {
              final commaIndex = cleanLine.lastIndexOf(',');
              if (commaIndex >= 0) {
                currentName = cleanLine.substring(commaIndex + 1).trim();
              }
            }
            currentLogo = _extractAttribute(cleanLine, 'logo');
            currentCategory = _extractAttribute(cleanLine, 'group-title');
            currentTvgId = _extractAttribute(cleanLine, 'tvg-id');

            if (currentCategory.isEmpty) currentCategory = 'Uncategorized';
            categoriesSet.add(currentCategory);
          } else if (!cleanLine.startsWith('#')) {
            if (cleanLine.startsWith('http://') || cleanLine.startsWith('https://')) {
              _allChannelsList.add(
                ChannelItem(
                  name: currentName.isEmpty ? 'Unknown Channel' : currentName,
                  logoUrl: currentLogo,
                  streamUrl: cleanLine,
                  category: currentCategory,
                  tvgId: currentTvgId,
                ),
              );
              currentName = '';
              currentLogo = '';
              currentTvgId = '';
            }
          }
        }

        final prefs = await SharedPreferences.getInstance();
        final savedFavs = prefs.getStringList('favorite_names') ?? [];

        if (!mounted) return;
        setState(() {
          _favoritesList.addAll(savedFavs);
          _categoriesList.addAll(categoriesSet.toList()..sort());
        });
        _fetchEpg();
        await _finishBoot();
      } else {
        await _finishBoot();
      }
    } catch (e) {
      debugPrint('Playlist error: $e');
      await _finishBoot();
    }
  }

  DateTime? _parseXmltvDate(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    try {
      return DateTime.parse(value).toLocal();
    } catch (_) {}

    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$').firstMatch(value);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    final sign = match.group(7);
    final tzHour = int.tryParse(match.group(8) ?? '0') ?? 0;
    final tzMinute = int.tryParse(match.group(9) ?? '0') ?? 0;

    if (sign == null) {
      return DateTime(year, month, day, hour, minute, second);
    }

    final offset = Duration(hours: tzHour, minutes: tzMinute);
    final utc = DateTime.utc(year, month, day, hour, minute, second);
    return (sign == '+') ? utc.subtract(offset).toLocal() : utc.add(offset).toLocal();
  }

  String _epgNameKey(String value) {
    var v = value.toLowerCase().trim().replaceAll('&amp;', '&');
    v = v.replaceAll(RegExp(r'\bsony entertainment television\b'), 'set');
    v = v.replaceAll(RegExp(r'\bsony hd\b'), 'set hd');
    v = v.replaceAll(RegExp(r'\bfull hd\b'), ' ');
    v = v.replaceAll(RegExp(r'\bhigh definition\b'), ' ');
    v = v.replaceAll(RegExp(r'\b(\d+\s*)?(hd|sd)\b'), ' ');
    v = v.replaceAll(RegExp(r'\b(india|indian|tv channel|channel)\b'), ' ');
    v = v.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _decodeXmlText(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.tryParse(m.group(1)!) ?? 32));
  }

  String _cleanEpgText(String value) {
    return _decodeXmlText(value.replaceAll(RegExp(r'<[^>]+>'), '').trim());
  }

  String _englishXmlText(String body, String tag) {
    final matches = RegExp('<$tag\\b([^>]*)>(.*?)</$tag\\s*>', caseSensitive: false, dotAll: true).allMatches(body);
    String? firstText;
    for (final match in matches) {
      final attrs = match.group(1) ?? '';
      final text = _cleanEpgText(match.group(2) ?? '');
      if (text.isEmpty) continue;
      firstText ??= text;

      final langMatch = RegExp(r'''\blang\s*=\s*["']([^"']+)["']''', caseSensitive: false).firstMatch(attrs);
      final lang = langMatch?.group(1)?.toLowerCase() ?? '';
      if (lang == 'en' || lang.startsWith('en-') || lang.startsWith('en_') || lang == 'eng' || lang == 'english') {
        return text;
      }
    }
    return firstText ?? '';
  }

  String? _xmlIconUrl(String body) {
    final match = RegExp(r'''<icon\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>''', caseSensitive: false).firstMatch(body);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : _decodeXmlText(value);
  }

  Future<void> _fetchEpg() async {
    final urls = <String>[
      if (_playlistEpgUrl != null && _playlistEpgUrl!.isNotEmpty) _playlistEpgUrl!,
      'https://github.io',
      'https://epgshare01.online',
      'https://iptv-epg.org',
    ].toSet().toList();

    final merged = <String, EpgData>{};

    EpgData buildData(List<EpgProgram>? source) {
      if (source == null || source.isEmpty) return const EpgData();
      final sorted = List<EpgProgram>.from(source)..sort((a, b) => a.start.compareTo(b.start));
      final now = DateTime.now();
      EpgProgram? current;
      final future = <EpgProgram>[];

      for (final program in sorted) {
        if (!program.start.isAfter(now) && program.stop.isAfter(now)) {
          current ??= program;
        } else if (program.start.isAfter(now)) {
          future.add(program);
        }
      }
      return EpgData(now: current, next: future.isNotEmpty ? future.first : null, upcoming: future.take(6).toList());
    }

    bool hasUsefulData(EpgData data) => data.now != null || data.next != null || data.upcoming.isNotEmpty;

    EpgProgram? mergeProgram(EpgProgram? preferred, EpgProgram? fallback) {
      if (preferred == null) return fallback;
      if (fallback == null) return preferred;
      return EpgProgram(
        start: preferred.start,
        stop: preferred.stop,
        title: preferred.title,
        description: preferred.description.isNotEmpty ? preferred.description : fallback.description,
        imageUrl: preferred.imageUrl?.isNotEmpty == true ? preferred.imageUrl : fallback.imageUrl,
      );
    }

    EpgData mergeData(EpgData oldData, EpgData newData) {
      final now = mergeProgram(newData.now, oldData.now);
      final next = mergeProgram(newData.next, oldData.next);
      final allUpcoming = <String, EpgProgram>{};
      for (final p in oldData.upcoming) {
        allUpcoming['${p.start.millisecondsSinceEpoch}|${p.stop.millisecondsSinceEpoch}|${p.title}'] = p;
      }
      for (final p in newData.upcoming) {
        allUpcoming['${p.start.millisecondsSinceEpoch}|${p.stop.millisecondsSinceEpoch}|${p.title}'] = p;
      }
      final upcoming = allUpcoming.values.toList()..sort((a, b) => a.start.compareTo(b.start));
      return EpgData(now: now, next: next, upcoming: upcoming.take(6).toList());
    }

    for (final url in urls) {
      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
        if (response.statusCode < 200 || response.statusCode >= 300) continue;

        String xml;
        final bytes = response.bodyBytes;
        if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
xml = utf8.decode(GZipCodec().decode(bytes), allowMalformed: true);
} else {
xml = utf8.decode(bytes, allowMalformed: true);
}
final channelNames = <String, String>{};
final channelRegex = RegExp(r'<channel\b[^>]\bid\s=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r'][^>]>(.?)</channel\s*>', caseSensitive: false, dotAll: true);
final displayRegex = RegExp(r'<display-name\b[^>]>(.?)</display-name\s*>', caseSensitive: false, dotAll: true);
for (final m in channelRegex.allMatches(xml)) {
final id = m.group(1)!.trim();
final body = m.group(2)!;
final dm = displayRegex.firstMatch(body);
if (dm != null) {
channelNames[id] = _decodeXmlText(dm.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim());
}
}
final programmes = <String, List>{};
final programmeRegex = RegExp(r'<programme\b([^>])>(.?)</programme\s*>', caseSensitive: false, dotAll: true);
final channelAttr = RegExp(r'\bchannel\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']', caseSensitive: false);
final attrStart = RegExp(r'\bstart\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']', caseSensitive: false);
final attrStop = RegExp(r'\bstop\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']', caseSensitive: false);
for (final m in programmeRegex.allMatches(xml)) {
final attrs = m.group(1)!;
final body = m.group(2)!;
final channelId = channelAttr.firstMatch(attrs)?.group(1)?.trim();
final startRaw = attrStart.firstMatch(attrs)?.group(1);
final stopRaw = attrStop.firstMatch(attrs)?.group(1);
if (channelId == null || channelId.isEmpty || startRaw == null || stopRaw == null) continue;
final start = _parseXmltvDate(startRaw);
final stop = _parseXmltvDate(stopRaw);
if (start == null || stop == null || !stop.isAfter(start)) continue;
final title = _englishXmlText(body, 'title');
if (title.isEmpty) continue;
final description = _englishXmlText(body, 'desc');
final imageUrl = _xmlIconUrl(body);
(programmes[channelId] ??= []).add(EpgProgram(start: start, stop: stop, title: title, description: description, imageUrl: imageUrl));
}
final byName = <String, List>{};
programmes.forEach((id, list) {
final display = channelNames[id];
if (display == null || display.trim().isEmpty) return;
final key = _epgNameKey(display);
if (key.isNotEmpty) (byName[key] ??= []).addAll(list);
});
for (final channel in _allChannelsList) {
final resultKey = channel.tvgId.trim().isNotEmpty ? channel.tvgId.trim() : channel.name;
List? matched;
final id = channel.tvgId.trim();
if (id.isNotEmpty) {
matched = programmes[id];
if (matched == null) {
for (final entry in programmes.entries) {
if (entry.key.toLowerCase() == id.toLowerCase()) {
matched = entry.value;
break;
}
}
}
}
final channelKey = _epgNameKey(channel.name);
matched ??= byName[channelKey];
if (matched == null && channelKey.isNotEmpty) {
int bestScore = 0;
for (final entry in byName.entries) {
final epgKey = entry.key;
int score = 0;
if (epgKey == channelKey) {
score = 100;
} else if (epgKey.contains(channelKey) || channelKey.contains(epgKey)) {
score = 80;
} else {
final channelTokens = _epgTokens(channelKey);
final epgTokens = _epgTokens(epgKey);
final overlap = channelTokens.intersection(epgTokens).length;
if (overlap >= 2) score = 50 + overlap;
}
if (score > bestScore) {
bestScore = score;
matched = entry.value;
}
}
}
