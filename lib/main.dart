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

  ChannelItem({
    required this.name,
    required this.logoUrl,
    required this.streamUrl,
    required this.category,
  });
}

class EpgProgram {
  final DateTime start;
  final DateTime stop;
  final String title;
  const EpgProgram({required this.start, required this.stop, required this.title});
}

class EpgData {
  final EpgProgram? now;
  final EpgProgram? next;
  const EpgData({this.now, this.next});
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
        final categoriesSet = <String>{};

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
                ),
              );
              currentName = '';
              currentLogo = '';
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


  String _normalizeEpgName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'&amp;|&#38;'), '&')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '')
        .replaceAll(RegExp(r'hd|sd|fhd|uhd'), '');
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

  Future<void> _fetchEpg() async {
    const urls = <String>[
      'https://iptv-org.github.io/epg/guides/in.xml.gz',
      'https://epgshare01.online/epgshare01/epg_ripper_IN1.xml.gz',
      'https://iptv-epg.org/files/epg-in.xml.gz',
    ];

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
        final channelRegex = RegExp(
          r'<channel\s+[^>]*id="([^"]+)"[^>]*>(.*?)</channel>',
          caseSensitive: false,
          dotAll: true,
        );
        final displayRegex = RegExp(r'<display-name[^>]*>(.*?)</display-name>', caseSensitive: false, dotAll: true);
        for (final m in channelRegex.allMatches(xml)) {
          final id = m.group(1)!.trim();
          final body = m.group(2)!;
          final dm = displayRegex.firstMatch(body);
          if (dm != null) channelNames[id] = _decodeXmlText(dm.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim());
        }

        final programmes = <String, List<EpgProgram>>{};
        final programmeRegex = RegExp(
          r'<programme\s+([^>]*channel="([^"]+)"[^>]*)>(.*?)</programme>',
          caseSensitive: false,
          dotAll: true,
        );
        final attrStart = RegExp(r'\bstart="([^"]+)"', caseSensitive: false);
        final attrStop = RegExp(r'\bstop="([^"]+)"', caseSensitive: false);
        final titleRegex = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);

        for (final m in programmeRegex.allMatches(xml)) {
          final attrs = m.group(1)!;
          final channelId = m.group(2)!.trim();
          final body = m.group(3)!;
          final startRaw = attrStart.firstMatch(attrs)?.group(1);
          final stopRaw = attrStop.firstMatch(attrs)?.group(1);
          final titleMatch = titleRegex.firstMatch(body);
          if (startRaw == null || stopRaw == null || titleMatch == null) continue;
          DateTime? start;
          DateTime? stop;
          try {
            start = DateTime.parse(startRaw.trim());
            stop = DateTime.parse(stopRaw.trim());
          } catch (_) {
            continue;
          }
          final title = _decodeXmlText(titleMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim());
          if (title.isEmpty) continue;
          (programmes[channelId] ??= []).add(EpgProgram(start: start, stop: stop, title: title));
        }

        final now = DateTime.now();
        final byName = <String, List<EpgProgram>>{};
        programmes.forEach((id, list) {
          final display = channelNames[id];
          if (display == null) return;
          final key = _normalizeEpgName(display);
          if (key.isEmpty) return;
          byName[key] = list;
        });

        final result = <String, EpgData>{};
        for (final channel in _allChannelsList) {
          final key = _normalizeEpgName(channel.name);
          List<EpgProgram>? list = byName[key];
          if (list == null) {
            for (final entry in byName.entries) {
              if (entry.key == key || entry.key.contains(key) || key.contains(entry.key)) {
                list = entry.value;
                break;
              }
            }
          }
          if (list == null) continue;
          list.sort((a, b) => a.start.compareTo(b.start));
          EpgProgram? current;
          EpgProgram? next;
          for (final p in list) {
            if (p.start.isBefore(now) && p.stop.isAfter(now)) {
              current = p;
            } else if (p.start.isAfter(now)) {
              next = p;
              break;
            }
          }
          if (current != null || next != null) result[channel.name] = EpgData(now: current, next: next);
        }

        if (mounted) {
          setState(() {
            _epgByChannel
              ..clear()
              ..addAll(result);
          });
        }
        debugPrint('EPG loaded: ${result.length} channels from $url');
        return;
      } catch (e) {
        debugPrint('EPG source failed $url: $e');
      }
    }
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
    final data = _epgByChannel[channel.name];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('YOU ARE WATCHING', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('EPG • PROGRAMME GUIDE', style: TextStyle(color: ShroudyColors.primaryRed, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (data?.now != null) ...[
            const Text('LIVE NOW', style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Text(data!.now!.title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Text('${_formatEpgTime(data.now!.start)} – ${_formatEpgTime(data.now!.stop)}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ] else
            const Text('No LIVE NOW programme found.', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 16),
          if (data?.next != null) ...[
            const Text('NEXT', style: TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Text(data!.next!.title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 5),
            Text('${_formatEpgTime(data.next!.start)} – ${_formatEpgTime(data.next!.stop)}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
          if (data == null) ...[
            const SizedBox(height: 10),
            const Text('EPG is loading or this channel could not be matched.', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
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
                  'NOW PLAYING: ${_currentChannel!.name.toUpperCase()}',
                  style: const TextStyle(color: ShroudyColors.primaryRed, fontSize: 20, fontWeight: FontWeight.bold),
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
          child: Align(alignment: Alignment.centerLeft, child: Text('★ CHANNELS FROM SAME CATEGORY', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
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

  VlcVideoFit _currentFit = VlcVideoFit.contain;
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

    // All three modes preserve the source image. The AspectRatio wrapper below
    // controls the physical display rectangle; VLC contain prevents distortion/cropping.
    newFit = VlcVideoFit.contain;

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
    _controller.removeListener(_playerListener);
    _controller.dispose();
    super.dispose();
  }

  Widget _buildVideoWidget(VlcVideoFit fit) {
    final player = VlcPlayer(
      controller: _controller,
      backgroundColor: Colors.black,
      fit: VlcVideoFit.contain,
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
      fit: VlcVideoFit.contain,
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

class BorderBorder extends Border {
  const BorderBorder({required BorderSide side, double width = 1.0})
      : super(top: side, bottom: side, left: side, right: side);
}
