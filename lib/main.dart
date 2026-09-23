import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
      title: 'Shroudy TV iPad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: ShroudyColors.darkNavyBg,
        primaryColor: ShroudyColors.primaryRed,
      ),
      home: const MainDashboard(),
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

  @override
  void initState() {
    super.initState();
    _fetchM3uPlaylist();
    _epgRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshCurrentEpg());
  }

  Future<void> _fetchM3uPlaylist() async {
    try {
      final response = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/shroudybuoy/TV-Channels/refs/heads/main/channel%20playlist.m3u',
      ));

      if (response.statusCode == 200) {
        final lines = response.body.split('\n');
        String currentName = '';
        String currentLogo = '';
        String currentCategory = 'Uncategorized';
        String currentTvgId = '';
        final categoriesSet = <String>{};

        // Use the EPG URL declared by the playlist header.
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
          _isLoading = false;
        });
        _fetchEpg();
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Playlist error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }


  DateTime? _parseXmltvDate(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    try {
      return DateTime.parse(value).toLocal();
    } catch (_) {}

    // XMLTV commonly uses: yyyyMMddHHmmss +0000 / yyyyMMddHHmmss -0500
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

  String _normalizeEpgName(String value) {
    var v = value.toLowerCase().trim().replaceAll('&amp;', '&');
    v = v.replaceAll(RegExp(r'\bsony entertainment television\b'), 'set');
    v = v.replaceAll(RegExp(r'\bsony hd\b'), 'set hd');
    return v.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _epgNameKey(String value) {
    var v = value.toLowerCase().trim().replaceAll('&amp;', '&');
    v = v.replaceAll(RegExp(r'\bsony entertainment television\b'), 'set');
    v = v.replaceAll(RegExp(r'\bsony hd\b'), 'set hd');

    // Normalize common provider/channel-name differences so the same
    // channel can be matched even when M3U and XMLTV use different labels.
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
    final matches = RegExp(
      '<$tag\\b([^>]*)>(.*?)</$tag\\s*>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(body);

    String? firstText;
    for (final match in matches) {
      final attrs = match.group(1) ?? '';
      final text = _cleanEpgText(match.group(2) ?? '');
      if (text.isEmpty) continue;
      firstText ??= text;

      final langMatch = RegExp(
        r'''\blang\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(attrs);
      final lang = langMatch?.group(1)?.toLowerCase() ?? '';

      if (lang == 'en' ||
          lang.startsWith('en-') ||
          lang.startsWith('en_') ||
          lang == 'eng' ||
          lang == 'english') {
        return text;
      }
    }
    return firstText ?? '';
  }

  String? _xmlIconUrl(String body) {
    final match = RegExp(
      r'''<icon\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>''',
      caseSensitive: false,
    ).firstMatch(body);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : _decodeXmlText(value);
  }

  Future<void> _fetchEpg() async {
    final urls = <String>[
      if (_playlistEpgUrl != null && _playlistEpgUrl!.isNotEmpty) _playlistEpgUrl!,
      'https://iptv-org.github.io/epg/guides/in.xml.gz',
      'https://epgshare01.online/epgshare01/epg_ripper_IN1.xml.gz',
      'https://iptv-epg.org/files/epg-in.xml.gz',
    ].toSet().toList();

    // Do NOT stop after the first working EPG source.
    // A source can be reachable but contain only a small subset of channels.
    // We merge matches from every source so sparse EPG files can fill gaps.
    final merged = <String, EpgData>{};

    EpgData buildData(List<EpgProgram>? source) {
      if (source == null || source.isEmpty) {
        return const EpgData();
      }

      final sorted = List<EpgProgram>.from(source)
        ..sort((a, b) => a.start.compareTo(b.start));

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

      return EpgData(
        now: current,
        next: future.isNotEmpty ? future.first : null,
        upcoming: future.take(6).toList(),
      );
    }

    bool hasUsefulData(EpgData data) =>
        data.now != null || data.next != null || data.upcoming.isNotEmpty;

    EpgProgram? mergeProgram(EpgProgram? preferred, EpgProgram? fallback) {
      if (preferred == null) return fallback;
      if (fallback == null) return preferred;
      return EpgProgram(
        start: preferred.start,
        stop: preferred.stop,
        title: preferred.title,
        description: preferred.description.isNotEmpty
            ? preferred.description
            : fallback.description,
        imageUrl: preferred.imageUrl?.isNotEmpty == true
            ? preferred.imageUrl
            : fallback.imageUrl,
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

      final upcoming = allUpcoming.values.toList()
        ..sort((a, b) => a.start.compareTo(b.start));

      return EpgData(
        now: now,
        next: next,
        upcoming: upcoming.take(6).toList(),
      );
    }

    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 25));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          debugPrint('EPG source HTTP ${response.statusCode}: $url');
          continue;
        }

        String xml;
        final bytes = response.bodyBytes;
        if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
          xml = utf8.decode(GZipCodec().decode(bytes), allowMalformed: true);
        } else {
          xml = utf8.decode(bytes, allowMalformed: true);
        }

        final channelNames = <String, String>{};

        final channelRegex = RegExp(
          r'<channel\b[^>]*\bid\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r'][^>]*>(.*?)</channel\s*>',
          caseSensitive: false,
          dotAll: true,
        );

        final displayRegex = RegExp(
          r'<display-name\b[^>]*>(.*?)</display-name\s*>',
          caseSensitive: false,
          dotAll: true,
        );

        for (final m in channelRegex.allMatches(xml)) {
          final id = m.group(1)!.trim();
          final body = m.group(2)!;
          final dm = displayRegex.firstMatch(body);
          if (dm != null) {
            channelNames[id] = _decodeXmlText(
              dm.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim(),
            );
          }
        }

        final programmes = <String, List<EpgProgram>>{};

        // Match programme elements regardless of attribute ordering and
        // support both single- and double-quoted XML attributes.
        final programmeRegex = RegExp(
          r'<programme\b([^>]*)>(.*?)</programme\s*>',
          caseSensitive: false,
          dotAll: true,
        );

        final channelAttr = RegExp(
          r'\bchannel\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']',
          caseSensitive: false,
        );
        final attrStart = RegExp(
          r'\bstart\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']',
          caseSensitive: false,
        );
        final attrStop = RegExp(
          r'\bstop\s*=\s*["' + "'" + r']([^"' + "'" + r']+)["' + "'" + r']',
          caseSensitive: false,
        );
        for (final m in programmeRegex.allMatches(xml)) {
          final attrs = m.group(1)!;
          final body = m.group(2)!;

          final channelId = channelAttr.firstMatch(attrs)?.group(1)?.trim();
          final startRaw = attrStart.firstMatch(attrs)?.group(1);
          final stopRaw = attrStop.firstMatch(attrs)?.group(1);

          if (channelId == null ||
              channelId.isEmpty ||
              startRaw == null ||
              stopRaw == null) {
            continue;
          }

          final start = _parseXmltvDate(startRaw);
          final stop = _parseXmltvDate(stopRaw);
          if (start == null || stop == null || !stop.isAfter(start)) continue;

          // Prefer the English XMLTV title when the provider supplies one.
          // If no English field exists, retain the provider's first title.
          final title = _englishXmlText(body, 'title');
          if (title.isEmpty) continue;

          final description = _englishXmlText(body, 'desc');
          final imageUrl = _xmlIconUrl(body);

          (programmes[channelId] ??= []).add(
            EpgProgram(
              start: start,
              stop: stop,
              title: title,
              description: description,
              imageUrl: imageUrl,
            ),
          );
        }

        // Create a normalized display-name index for this source.
        final byName = <String, List<EpgProgram>>{};
        programmes.forEach((id, list) {
          final display = channelNames[id];
          if (display == null || display.trim().isEmpty) return;

          final key = _epgNameKey(display);
          if (key.isNotEmpty) {
            (byName[key] ??= <EpgProgram>[]).addAll(list);
          }
        });

        for (final channel in _allChannelsList) {
          final resultKey = channel.tvgId.trim().isNotEmpty
              ? channel.tvgId.trim()
              : channel.name;

          List<EpgProgram>? matched;

          // 1. Exact tvg-id match.
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

          // 2. Exact normalized channel-name match.
          final channelKey = _epgNameKey(channel.name);
          matched ??= byName[channelKey];

          // 3. Fuzzy normalized-name match for provider naming differences.
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

          if (matched == null || matched.isEmpty) continue;

          final data = buildData(matched);
          if (!hasUsefulData(data)) continue;

          final previous = merged[resultKey];
          merged[resultKey] =
              previous == null ? data : mergeData(previous, data);
        }

        debugPrint(
          'EPG source parsed: ${programmes.length} XMLTV IDs, '
          '${merged.length} matched playlist channels from $url',
        );
      } catch (e) {
        debugPrint('EPG source failed $url: $e');
      }
    }

    if (!mounted) return;

    setState(() {
      _epgByChannel
        ..clear()
        ..addAll(merged);
    });

    debugPrint('EPG merged: ${merged.length}/${_allChannelsList.length} channels');
  }

  Set<String> _epgTokens(String value) {
    final ignored = <String>{
      'tv', 'television', 'channel', 'india', 'hd', 'sd',
      'english', 'hindi', 'live', 'network',
    };

    return value
        .split(RegExp(r'[^a-z0-9]+'))
        .where((e) => e.length >= 2 && !ignored.contains(e))
        .toSet();
  }

  Future<void> _refreshCurrentEpg() async {
    if (_allChannelsList.isNotEmpty) await _fetchEpg();
  }

  @override
  void dispose() {
    _epgRefreshTimer?.cancel();
    super.dispose();
  }

  String _extractAttribute(String line, String attributeName) {
    final regExp = RegExp('$attributeName\\s*=\\s*"([^"]*)"', caseSensitive: false);
    return regExp.firstMatch(line)?.group(1)?.trim() ?? '';
  }

  Future<void> _toggleFavorite(String name) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_favoritesList.contains(name)) {
        _favoritesList.remove(name);
      } else {
        _favoritesList.add(name);
      }
    });
    await prefs.setStringList('favorite_names', _favoritesList);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: ShroudyColors.primaryRed)),
      );
    }

    final filteredChannels = _allChannelsList.where((ch) {
      final matchesSearch = ch.name.toLowerCase().contains(_searchQuery.toLowerCase());
      if (_selectedCategory == '★ Favorites') {
        return _favoritesList.contains(ch.name) && matchesSearch;
      }
      final matchesCat = _selectedCategory == 'All' || ch.category == _selectedCategory;
      return matchesCat && matchesSearch;
    }).toList();

    return Scaffold(
      body: _currentChannel != null
          ? _buildPremiumSplitPlayerLayoutView(filteredChannels)
          : _buildStandardBrowsingHubView(filteredChannels),
    );
  }
  Widget _buildStandardBrowsingHubView(List<ChannelItem> channels) {
    return Column(
      children: [
        _buildCategoryAndSearchHeaderRow(),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 1.0,
            ),
            itemCount: channels.length,
            itemBuilder: (context, index) => _buildChannelItemCard(channels[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryAndSearchHeaderRow() {
    final finalCategories = [
      'All',
      if (_favoritesList.isNotEmpty) '★ Favorites',
      ..._categoriesList.sublist(1),
    ];

    return Container(
      padding: const EdgeInsets.only(top: 40, left: 16, right: 16, bottom: 12),
      child: Column(
        children: [
          SizedBox(
            height: 45,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: finalCategories.length,
              itemBuilder: (context, i) {
                final cat = finalCategories[i];
                final isSelected = cat == _selectedCategory;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    selected: isSelected,
                    selectedColor: ShroudyColors.primaryRed,
                    backgroundColor: ShroudyColors.cardNavyBg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    onSelected: (val) => setState(() => _selectedCategory = cat),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            onChanged: (val) => setState(() => _searchQuery = val),
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search channels...',
              hintStyle: const TextStyle(color: Colors.grey),
              fillColor: ShroudyColors.cardNavyBg,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelItemCard(ChannelItem channel) {
    return Card(
      color: ShroudyColors.cardNavyBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: InkWell(
        onTap: () => setState(() => _currentChannel = channel),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: ShroudyColors.innerLogoBg,
                  width: double.infinity,
                  child: Image.network(
                    channel.logoUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(channel.name, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              const Text('● LIVE', style: TextStyle(color: ShroudyColors.liveIndicator, fontSize: 8, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildEpgPanel(ChannelItem channel) {
    final epgKey = channel.tvgId.trim().isNotEmpty
        ? channel.tvgId.trim()
        : channel.name;
    final data = _epgByChannel[epgKey];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(
            child: Text(
              'YOU ARE WATCHING',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 110,
              height: 76,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ShroudyColors.innerLogoBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ShroudyColors.accentBorder),
              ),
              child: channel.logoUrl.trim().isEmpty
                  ? const Icon(Icons.tv, color: Colors.white, size: 34)
                  : Image.network(
                      channel.logoUrl,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.tv, color: Colors.white, size: 34),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              channel.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'PROGRAMME GUIDE',
            style: TextStyle(
              color: Color.fromARGB(255, 71, 24, 243),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          if (data?.now != null)
            _buildLiveNowCard(data!.now!, channel.logoUrl)
          else
            const Text(
              'No LIVE NOW programme found.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),

          const SizedBox(height: 16),

          if (data?.next != null) ...[
            const Text(
              'NEXT',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            _buildEpgProgrammeRow(data!.next!, channel.logoUrl),
          ],

          const SizedBox(height: 18),

          if (data?.upcoming.isNotEmpty == true) ...[
            const Text(
              'UPCOMING',
              style: TextStyle(
                color: Colors.lightBlueAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...data!.upcoming.skip(1).take(5).map(
              (program) => _buildEpgProgrammeRow(program, channel.logoUrl),
            ),
          ] else if (data != null) ...[
            const Text(
              'No additional upcoming programmes found.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],

          if (data == null) ...[
            const SizedBox(height: 10),
            const Text(
              'EPG is loading or this channel could not be matched.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiveNowCard(EpgProgram program, String channelLogoUrl) {
    final imageUrl = (program.imageUrl?.trim().isNotEmpty == true)
        ? program.imageUrl!.trim()
        : channelLogoUrl.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ShroudyColors.innerLogoBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.greenAccent.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LIVE NOW',
            style: TextStyle(
              color: Color.fromARGB(255, 241, 59, 4),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.black26,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.live_tv,
                      color: Colors.white54,
                      size: 34,
                    ),
                  ),
                ),
              ),
            )
          else
            Container(
              height: 130,
              width: double.infinity,
              color: Colors.black26,
              alignment: Alignment.center,
              child: const Icon(Icons.live_tv, color: Colors.white54, size: 34),
            ),
          const SizedBox(height: 9),
          Text(
            program.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${_formatEpgTime(program.start)} – ${_formatEpgTime(program.stop)}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          if (program.description.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              program.description.trim(),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEpgProgrammeRow(EpgProgram program, String channelLogoUrl) {
    final imageUrl = (program.imageUrl?.trim().isNotEmpty == true)
        ? program.imageUrl!.trim()
        : channelLogoUrl.trim();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: ShroudyColors.innerLogoBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                imageUrl,
                width: 72,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 72,
                  height: 48,
                  color: Colors.black26,
                  alignment: Alignment.center,
                  child: const Icon(Icons.tv, color: Colors.white54, size: 22),
                ),
              ),
            )
          else
            Container(
              width: 72,
              height: 48,
              color: Colors.black26,
              alignment: Alignment.center,
              child: const Icon(Icons.tv, color: Colors.white54, size: 22),
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  program.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatEpgTime(program.start)} – ${_formatEpgTime(program.stop)}',
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                ),
                if (program.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    program.description.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatEpgTime(DateTime value) {
    final local = value.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  Widget _buildPremiumSplitPlayerLayoutView(List<ChannelItem> channels) {
    final relatedChannels = _allChannelsList
        .where((ch) => ch.category == _currentChannel!.category && ch.name != _currentChannel!.name)
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 40, left: 24, right: 24, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'PLAYING: ${_currentChannel!.name.toUpperCase()}',
                  style: const TextStyle(color: Color.fromARGB(255, 233, 68, 239), fontSize: 20, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => setState(() => _currentChannel = null),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ShroudyColors.cardNavyBg,
                  side: const BorderSide(color: ShroudyColors.accentBorder, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text('← Back', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: Container(
                    color: Colors.black,
                    child: VideoCanvasPlayerLayer(
                      key: ValueKey(_currentChannel!.streamUrl),
                      streamUrl: _currentChannel!.streamUrl,
                      channelName: _currentChannel!.name,
                      isFavorited: _favoritesList.contains(_currentChannel!.name),
                      onFavToggle: () => _toggleFavorite(_currentChannel!.name),
                      onClose: () => setState(() => _currentChannel = null),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 1,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: const BoxDecoration(
                      color: ShroudyColors.cardNavyBg,
                      border: BorderBorder(side: BorderSide(color: ShroudyColors.accentBorder, width: 1)),
                    ),
                    child: _buildEpgPanel(_currentChannel!),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 24, top: 16, bottom: 8),
          child: Align(alignment: Alignment.centerLeft, child: Text('★ CHANNELS FROM SAME CATEGORY', style: TextStyle(color: Color.fromARGB(255, 248, 203, 1), fontSize: 13, fontWeight: FontWeight.bold))),
        ),
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 24, right: 24, bottom: 20),
            child: relatedChannels.isEmpty
                ? const Center(child: Text('No related channels in this category', style: TextStyle(color: Colors.grey, fontSize: 12)))
                : GridView.builder(
                    padding: const EdgeInsets.only(right: 0),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.15,
                    ),
                    itemCount: relatedChannels.length,
                    itemBuilder: (context, idx) {
                      final relChannel = relatedChannels[idx];
                      return Card(
                        color: ShroudyColors.cardNavyBg,
                        margin: EdgeInsets.zero,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        child: InkWell(
                          onTap: () => setState(() => _currentChannel = relChannel),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              children: [
                                Expanded(
                                  child: Container(
                                    color: ShroudyColors.innerLogoBg,
                                    width: double.infinity,
                                    child: Image.network(
                                      relChannel.logoUrl,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  relChannel.name,
                                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
class VideoCanvasPlayerLayer extends StatefulWidget {
  final String streamUrl;
  final String channelName;
  final bool isFavorited;
  final VoidCallback onFavToggle;
  final VoidCallback onClose;

  const VideoCanvasPlayerLayer({
    super.key,
    required this.streamUrl,
    required this.channelName,
    required this.isFavorited,
    required this.onFavToggle,
    required this.onClose,
  });

  @override
  State<VideoCanvasPlayerLayer> createState() => _VideoCanvasPlayerLayerState();
}

class _VideoCanvasPlayerLayerState extends State<VideoCanvasPlayerLayer> {
  late VlcPlayerController _controller;

  bool _showControls = true;
  bool _isFullscreen = false;
  bool _isPlaying = false;
  String? _errorText;

  VlcVideoFit _currentFit = VlcVideoFit.fill;
  String _selectedAspectRatio = 'Fit to screen';
  int? _selectedAudioTrackId;
  int? _selectedSubtitleTrackId;

  List<VlcTrackDescription> _audioTracks = [];
  List<VlcTrackDescription> _subtitleTracks = [];

  Timer? _controlsTimer;

  // This notifier lets the fullscreen route immediately receive aspect-ratio
  // changes made in the settings dialog.
  late final ValueNotifier<VlcVideoFit> _fitNotifier;
  late final ValueNotifier<String> _aspectNotifier;

  // Shared gesture state so the normal and fullscreen views stay in sync.
  // Volume goes through VLC (0..100). Brightness is a local dim overlay
  // (0.15..1.0) so no native permission or plugin is required.
  final ValueNotifier<int> _volumeNotifier = ValueNotifier<int>(100);
  final ValueNotifier<double> _brightnessNotifier = ValueNotifier<double>(1.0);

  @override
  void initState() {
    super.initState();
    _fitNotifier = ValueNotifier<VlcVideoFit>(_currentFit);
    _aspectNotifier = ValueNotifier<String>(_selectedAspectRatio);
    _createController(widget.streamUrl);
    _showControlsTemporarily();
  }

  void _createController(String url) {
    _controller = VlcPlayerController(
      mediaSource: VlcMediaSource(
        uri: Uri.parse(url),
        mediaOptions: const [
          ':network-caching=1000',
          ':live-caching=1000',
          ':file-caching=1000',
          ':http-reconnect=true',
          ':clock-jitter=0',
          ':clock-synchro=0',
        ],
      ),
      autoPlay: true,
    );
    _controller.addListener(_playerListener);
    _isPlaying = true;
    _playingNotifier.value = true;
  }

  void _playerListener() {
    if (!mounted) return;

    final value = _controller.value;
    final playing = value.isPlaying;

    if (value.errorMessage != null && value.errorMessage!.isNotEmpty) {
      if (_errorText != value.errorMessage) {
        setState(() => _errorText = value.errorMessage);
      }
    }

    // Do not call setState on every VLC update unless something actually
    // changed. Excess rebuilds can interfere with native player controls.
    if (_isPlaying != playing) {
      _isPlaying = playing;
      _playingNotifier.value = playing;
      setState(() {});
    }

    _loadTracksOnce();
  }

  bool _tracksLoaded = false;

  Future<void> _loadTracksOnce() async {
    if (_tracksLoaded) return;

    try {
      // Native VLC can expose tracks a little after playback starts. Retry a few
      // times instead of permanently leaving the settings dialog empty.
      for (int attempt = 0; attempt < 5 && mounted; attempt++) {
        try {
          final aud = await _controller.getAudioTracks();
          final sub = await _controller.getSubtitleTracks();

          if (aud.isNotEmpty || sub.isNotEmpty) {
            _tracksLoaded = true;
            if (mounted) {
              setState(() {
                _audioTracks = aud;
                _subtitleTracks = sub;
              });
            }
            return;
          }
        } catch (e) {
          debugPrint('Track query attempt ${attempt + 1}: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('Media tracks are not ready yet: $e');
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() => _showControls = true);
    _scheduleControlsHide();
  }

  Future<void> _togglePlayPause() async {
    _showControlsTemporarily();
    final targetPlaying = !_isPlaying;
    _isPlaying = targetPlaying;
    _playingNotifier.value = targetPlaying;
    if (mounted) setState(() {});

    try {
      // Send exactly one native command. Do not recreate media or controller.
      if (targetPlaying) {
        await _controller.play();
      } else {
        await _controller.pause();
      }
      // Some VLC builds update value.isPlaying asynchronously; let the native
      // listener correct the icon when the native state arrives.
    } catch (e) {
      debugPrint('VLC play/pause error: $e');
      if (!mounted) return;
      _isPlaying = !targetPlaying;
      _playingNotifier.value = _isPlaying;
      setState(() {});
    }
  }

  Future<void> _toggleFullscreen() async {
    _showControlsTemporarily();

    if (_isFullscreen) {
      Navigator.of(context).pop();
      return;
    }

    setState(() => _isFullscreen = true);

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (!mounted) return;

    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        barrierColor: Colors.black,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => _FullscreenVlcView(
          controller: _controller,
          channelName: widget.channelName,
          fitNotifier: _fitNotifier,
          aspectNotifier: _aspectNotifier,
          isPlayingNotifier: _playingNotifier,
          volumeNotifier: _volumeNotifier,
          brightnessNotifier: _brightnessNotifier,
          isFavorited: widget.isFavorited,
          onFavToggle: widget.onFavToggle,
          onSettings: _openPlayerSettingsDialog,
          onPlayPause: _togglePlayPause,
          onExit: () => Navigator.of(context).pop(),
          onTouch: _showControlsTemporarily,
        ),
      ),
    );

    // The SAME VLC controller is still alive. Explicitly resume it after
    // returning because some versions of the plugin pause native rendering
    // while the route is being changed.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (!mounted) return;

    setState(() => _isFullscreen = false);

    // Do not call play(), pause(), stop(), or setMedia() here. The controller
    // remains the same controller, so changing fullscreen must not intentionally
    // restart the live stream or change the user's play/pause choice.
    _isPlaying = _controller.value.isPlaying;
    _playingNotifier.value = _isPlaying;

    _showControlsTemporarily();
  }

  late final ValueNotifier<bool> _playingNotifier = ValueNotifier<bool>(false);

  void _syncPlayingNotifier() {
    _playingNotifier.value = _isPlaying;
  }

  Future<void> _openPlayerSettingsDialog() async {
    await _loadTracksOnce();
    if (!mounted) return;

    String tempAspect = _selectedAspectRatio;
    int? tempAudio = _selectedAudioTrackId;
    int? tempSubtitle = _selectedSubtitleTrackId;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF071B32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: const Row(
                children: [
                  Icon(Icons.settings, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text(
                    'Player Settings',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDropdownRow(
                    label: 'Aspect Ratio:',
                    value: tempAspect,
                    items: const ['Fit to screen', '16:9', '4:3'],
                    onChanged: (val) => setDialogState(() => tempAspect = val!),
                  ),
                  const SizedBox(height: 12),
                  _buildDropdownRow(
                    label: 'Audio Track:',
                    value: tempAudio ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('Default', style: TextStyle(color: Colors.white)),
                      ),
                      ..._audioTracks.map(
                        (t) => DropdownMenuItem(
                          value: t.id,
                          child: Text(t.name, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => tempAudio = val == -1 ? null : val as int?),
                    isCustomItems: true,
                  ),
                  const SizedBox(height: 12),
                  _buildDropdownRow(
                    label: 'Subtitles:',
                    value: tempSubtitle ?? -1,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('None', style: TextStyle(color: Colors.white)),
                      ),
                      ..._subtitleTracks.map(
                        (t) => DropdownMenuItem(
                          value: t.id,
                          child: Text(t.name, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setDialogState(() => tempSubtitle = val == -1 ? null : val as int?),
                    isCustomItems: true,
                  ),
                ],
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      await _applySettings(tempAspect, tempAudio, tempSubtitle);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                    child: const Text(
                      'Apply & Save',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDropdownRow({
    required String label,
    required dynamic value,
    required List<dynamic> items,
    required ValueChanged<dynamic> onChanged,
    bool isCustomItems = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF040F1E),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
          width: 140,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<dynamic>(
              isExpanded: true,
              value: value,
              dropdownColor: const Color(0xFF040F1E),
              icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
              onChanged: onChanged,
              items: isCustomItems
                  ? items.cast<DropdownMenuItem<dynamic>>()
                  : items
                      .map(
                        (item) => DropdownMenuItem<dynamic>(
                          value: item,
                          child: Text(
                            item.toString(),
                            style: const TextStyle(color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _applySettings(String aspect, int? audioId, int? subtitleId) async {
    VlcVideoFit newFit;

    // Fit to screen intentionally stretches the stream to the complete
    // available player rectangle in both normal and fullscreen modes.
    newFit = aspect == 'Fit to screen'
        ? VlcVideoFit.fill
        : VlcVideoFit.contain;

    if (mounted) {
      setState(() {
        _selectedAspectRatio = aspect;
        _selectedAudioTrackId = audioId;
        _selectedSubtitleTrackId = subtitleId;
        _currentFit = newFit;
      });
    }
    _fitNotifier.value = newFit;
    _aspectNotifier.value = aspect;

    try {
      // Apply the selected audio track. null means leave the current track alone.
      if (audioId != null) {
        await _controller.setAudioTrack(audioId);
      }

      // Selecting "None" must actually disable subtitles.
      if (subtitleId == null) {
        await _controller.disableSubtitle();
      } else {
        await _controller.setSubtitleTrack(subtitleId);
      }
    } catch (e) {
      debugPrint('Track selection error: $e');
    }

    _showControlsTemporarily();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _fitNotifier.dispose();
    _aspectNotifier.dispose();
    _playingNotifier.dispose();
    _volumeNotifier.dispose();
    _brightnessNotifier.dispose();
    _controller.removeListener(_playerListener);
    _controller.dispose();
    super.dispose();
  }

  Widget _buildVideoWidget(VlcVideoFit fit) {
    final player = VlcPlayer(
      controller: _controller,
      backgroundColor: Colors.black,
      fit: fit,
    );

    switch (_selectedAspectRatio) {
      case '16:9':
        return Center(child: AspectRatio(aspectRatio: 16 / 9, child: player));
      case '4:3':
        return Center(child: AspectRatio(aspectRatio: 4 / 3, child: player));
      default:
        return Positioned.fill(child: player);
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncPlayingNotifier();

    // The fullscreen route owns the native VLC widget while it is open.
    if (_isFullscreen) {
      return const ColoredBox(color: Colors.black);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // VLC video. The selected aspect ratio changes the actual widget
        // bounds instead of merely cropping the source.
        _buildVideoWidget(_currentFit),

        // Left/right vertical drag: brightness / volume. Also paints the
        // dim overlay used to fake brightness reduction.
        _VideoGestureLayer(
          controller: _controller,
          volumeNotifier: _volumeNotifier,
          brightnessNotifier: _brightnessNotifier,
        ),

        // Transparent touch layer ABOVE the video. This is deliberate:
        // touching anywhere on the video immediately reveals controls.
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _showControlsTemporarily(),
            child: const SizedBox.expand(),
          ),
        ),

        if (_errorText != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Text(
                  'VLC playback error:\n$_errorText',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),

        if (_showControls)
          Positioned.fill(
            child: Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: IgnorePointer(
                      child: Text(
                        widget.channelName,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(blurRadius: 5, color: Colors.black),
                            Shadow(blurRadius: 10, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _playerIconButton(
                        icon: _isPlaying ? Icons.pause : Icons.play_arrow,
                        tooltip: _isPlaying ? 'Pause' : 'Play',
                        onPressed: _togglePlayPause,
                      ),
                      _playerIconButton(
                        icon: Icons.settings,
                        tooltip: 'Player Settings',
                        onPressed: _openPlayerSettingsDialog,
                      ),
                      _playerIconButton(
                        icon: widget.isFavorited ? Icons.star : Icons.star_border,
                        tooltip: 'Favorite',
                        iconColor: widget.isFavorited ? ShroudyColors.goldText : Colors.white,
                        onPressed: widget.onFavToggle,
                      ),
                      _playerIconButton(
                        icon: Icons.fullscreen,
                        tooltip: 'Fullscreen',
                        onPressed: _toggleFullscreen,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _playerIconButton({
    required IconData icon,
    required String tooltip,
    required FutureOr<void> Function() onPressed,
    Color iconColor = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () async {
            _showControlsTemporarily();
            await onPressed();
          },
          child: Tooltip(
            message: tooltip,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(120),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 25),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenVlcView extends StatefulWidget {
  final VlcPlayerController controller;
  final String channelName;
  final ValueNotifier<VlcVideoFit> fitNotifier;
  final ValueNotifier<String> aspectNotifier;
  final ValueNotifier<bool> isPlayingNotifier;
  final ValueNotifier<int> volumeNotifier;
  final ValueNotifier<double> brightnessNotifier;
  final bool isFavorited;
  final VoidCallback onFavToggle;
  final Future<void> Function() onSettings;
  final Future<void> Function() onPlayPause;
  final VoidCallback onExit;
  final VoidCallback onTouch;

  const _FullscreenVlcView({
    required this.controller,
    required this.channelName,
    required this.fitNotifier,
    required this.aspectNotifier,
    required this.isPlayingNotifier,
    required this.volumeNotifier,
    required this.brightnessNotifier,
    required this.isFavorited,
    required this.onFavToggle,
    required this.onSettings,
    required this.onPlayPause,
    required this.onExit,
    required this.onTouch,
  });

  @override
  State<_FullscreenVlcView> createState() => _FullscreenVlcViewState();
}

class _FullscreenVlcViewState extends State<_FullscreenVlcView> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _showControlsTemporarily();
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() => _showControls = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  Widget _buildFullscreenVideo(VlcVideoFit fit, String aspect) {
    final player = VlcPlayer(
      controller: widget.controller,
      backgroundColor: Colors.black,
      fit: fit,
    );

    if (aspect == '16:9') {
      return Center(child: AspectRatio(aspectRatio: 16 / 9, child: player));
    }
    if (aspect == '4:3') {
      return Center(child: AspectRatio(aspectRatio: 4 / 3, child: player));
    }
    return Positioned.fill(child: player);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: widget.aspectNotifier,
            builder: (_, aspect, __) {
              return ValueListenableBuilder<VlcVideoFit>(
                valueListenable: widget.fitNotifier,
                builder: (_, fit, __) => _buildFullscreenVideo(fit, aspect),
              );
            },
          ),

          // Left/right vertical drag: brightness / volume (shared with the
          // normal view via notifiers so state stays consistent).
          _VideoGestureLayer(
            controller: widget.controller,
            volumeNotifier: widget.volumeNotifier,
            brightnessNotifier: widget.brightnessNotifier,
          ),

          // This layer receives every touch on the video and never changes
          // playback by itself.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _showControlsTemporarily();
                widget.onTouch();
              },
              child: const SizedBox.expand(),
            ),
          ),

          if (_showControls)
            Positioned.fill(
              child: Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: IgnorePointer(
                        child: Text(
                          widget.channelName,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(blurRadius: 5, color: Colors.black),
                              Shadow(blurRadius: 10, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: widget.isPlayingNotifier,
                      builder: (_, playing, __) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _fullIconButton(
                              icon: playing ? Icons.pause : Icons.play_arrow,
                              tooltip: playing ? 'Pause' : 'Play',
                              onPressed: () async {
                                _showControlsTemporarily();
                                await widget.onPlayPause();
                              },
                            ),
                            _fullIconButton(
                              icon: Icons.settings,
                              tooltip: 'Player Settings',
                              onPressed: () async {
                                _showControlsTemporarily();
                                await widget.onSettings();
                              },
                            ),
                            _fullIconButton(
                              icon: widget.isFavorited ? Icons.star : Icons.star_border,
                              tooltip: 'Favorite',
                              iconColor:
                                  widget.isFavorited ? ShroudyColors.goldText : Colors.white,
                              onPressed: () {
                                _showControlsTemporarily();
                                widget.onFavToggle();
                              },
                            ),
                            _fullIconButton(
                              icon: Icons.fullscreen_exit,
                              tooltip: 'Exit Fullscreen',
                              onPressed: widget.onExit,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _fullIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color iconColor = Colors.white,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Tooltip(
            message: tooltip,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(125),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 27),
            ),
          ),
        ),
      ),
    );
  }
}

extension on VlcPlayerValue {
  String? get errorMessage => null;
}

enum _GestureSide { volume, brightness }

/// Transparent overlay that turns vertical drags on the left half of the
/// video into brightness changes and vertical drags on the right half into
/// volume changes. Also paints a black overlay whose alpha is derived from
/// [brightnessNotifier], which is how brightness reduction is faked without
/// needing a native screen-brightness plugin.
class _VideoGestureLayer extends StatefulWidget {
  final VlcPlayerController controller;
  final ValueNotifier<int> volumeNotifier;
  final ValueNotifier<double> brightnessNotifier;

  const _VideoGestureLayer({
    required this.controller,
    required this.volumeNotifier,
    required this.brightnessNotifier,
  });

  @override
  State<_VideoGestureLayer> createState() => _VideoGestureLayerState();
}

class _VideoGestureLayerState extends State<_VideoGestureLayer> {
  static const double _minBrightness = 0.15;
  static const double _dragRangePx = 200.0;

  _GestureSide? _activeSide;
  double _startY = 0;
  double _startValue = 0;
  bool _showIndicator = false;
  Timer? _hideTimer;

  void _onStart(DragStartDetails d, _GestureSide side) {
    _hideTimer?.cancel();
    _activeSide = side;
    _startY = d.globalPosition.dy;
    _startValue = side == _GestureSide.volume
        ? widget.volumeNotifier.value / 100.0
        : widget.brightnessNotifier.value;
    if (!_showIndicator) setState(() => _showIndicator = true);
  }

  void _onUpdate(DragUpdateDetails d, _GestureSide side) {
    if (_activeSide != side) return;
    // Dragging up increases the value; dragging down decreases it.
    final delta = (_startY - d.globalPosition.dy) / _dragRangePx;

    if (side == _GestureSide.volume) {
      final next = ((_startValue + delta) * 100).round().clamp(0, 100);
      if (next != widget.volumeNotifier.value) {
        widget.volumeNotifier.value = next;
        // Fire-and-forget: rapid drag updates should not queue up awaits.
        widget.controller.setVolume(next).catchError((Object e) {
          debugPrint('VLC setVolume error: $e');
        });
      }
    } else {
      final next = (_startValue + delta).clamp(_minBrightness, 1.0);
      if (next != widget.brightnessNotifier.value) {
        widget.brightnessNotifier.value = next;
      }
    }

    if (!_showIndicator) setState(() => _showIndicator = true);
    _hideTimer?.cancel();
  }

  void _onEnd(DragEndDetails d, _GestureSide side) {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      setState(() {
        _activeSide = null;
        _showIndicator = false;
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<double>(
          valueListenable: widget.brightnessNotifier,
          builder: (_, b, __) {
            final alpha = ((1.0 - b) * 255).round().clamp(0, 255);
            return IgnorePointer(
              child: ColoredBox(color: Colors.black.withAlpha(alpha)),
            );
          },
        ),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) => _onStart(d, _GestureSide.brightness),
                onVerticalDragUpdate: (d) => _onUpdate(d, _GestureSide.brightness),
                onVerticalDragEnd: (d) => _onEnd(d, _GestureSide.brightness),
                onVerticalDragCancel: () {
                  if (_activeSide == _GestureSide.brightness) {
                    _onEnd(DragEndDetails(), _GestureSide.brightness);
                  }
                },
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) => _onStart(d, _GestureSide.volume),
                onVerticalDragUpdate: (d) => _onUpdate(d, _GestureSide.volume),
                onVerticalDragEnd: (d) => _onEnd(d, _GestureSide.volume),
                onVerticalDragCancel: () {
                  if (_activeSide == _GestureSide.volume) {
                    _onEnd(DragEndDetails(), _GestureSide.volume);
                  }
                },
              ),
            ),
          ],
        ),
        if (_showIndicator && _activeSide != null)
          IgnorePointer(
            child: Align(
              alignment: _activeSide == _GestureSide.volume
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: _buildIndicator(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildIndicator() {
    final isVolume = _activeSide == _GestureSide.volume;
    final raw = isVolume
        ? widget.volumeNotifier.value / 100.0
        : (widget.brightnessNotifier.value - _minBrightness) / (1.0 - _minBrightness);
    final fraction = raw.clamp(0.0, 1.0);

    final int volValue = widget.volumeNotifier.value;
    final IconData icon = isVolume
        ? (volValue == 0
            ? Icons.volume_off
            : (volValue < 50 ? Icons.volume_down : Icons.volume_up))
        : Icons.brightness_6;

    final label = isVolume
        ? '$volValue%'
        : '${(widget.brightnessNotifier.value * 100).round()}%';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(170),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 26),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            width: 6,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: fraction,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class BorderBorder extends Border {
  const BorderBorder({required BorderSide side, double width = 1.0})
      : super(top: side, bottom: side, left: side, right: side);
}
