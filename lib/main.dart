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

  @override
  void initState() {
    super.initState();
    _fetchM3uPlaylist();
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
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Playlist error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
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
                    child: const SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('YOU ARE WATCHING', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          SizedBox(height: 16),
                          Text('EPG • PROGRAMME GUIDE', style: TextStyle(color: ShroudyColors.primaryRed, fontSize: 11, fontWeight: FontWeight.bold)),
                          SizedBox(height: 6),
                          Text('NOW • libVLC / VideoLAN decoder', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          SizedBox(height: 12),
                          Text('VLC-based playback supports network streams including MPEG-TS and HLS, subject to stream/server compatibility.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ),
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
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: relatedChannels.length,
                    itemBuilder: (context, idx) {
                      final relChannel = relatedChannels[idx];
                      return Container(
                        width: 140,
                        margin: const EdgeInsets.only(right: 12),
                        child: Card(
                          color: ShroudyColors.cardNavyBg,
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
                                      child: Image.network(relChannel.logoUrl, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white)),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(relChannel.name, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
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
  String? _errorText;
  VlcVideoFit _currentFit = VlcVideoFit.contain;

  @override
  void initState() {
    super.initState();
    _createController(widget.streamUrl);
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
  }

  void _playerListener() {
    if (!mounted) return;
    final value = _controller.value;
    if (value.errorMessage != null && value.errorMessage!.isNotEmpty) {
      setState(() => _errorText = value.errorMessage);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_playerListener);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_controller.value.isPlaying) {
        await _controller.pause();
      } else {
        await _controller.play();
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Playback error: $e');
    }
  }

  void _cycleAspectRatio() {
    setState(() {
      if (_currentFit == VlcVideoFit.contain) {
        _currentFit = VlcVideoFit.fill;
      } else if (_currentFit == VlcVideoFit.fill) {
        _currentFit = VlcVideoFit.cover;
      } else {
        _currentFit = VlcVideoFit.contain;
      }
    });
  }

      void _showTrackSelectionDialog(
    String title,
    List<VlcTrackDescription> tracks,
    Function(int) onSelected,
  ) {
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No alternative $title tracks found.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ShroudyColors.cardNavyBg,
        title: Text('Select $title', style: const TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 300,
          child: ListView(
            shrinkWrap: true,
            children: tracks.map((track) {
                            return ListTile(
                title: Text(
                  track.name,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  onSelected(track.id);
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _changeAudioTrack() async {
    final tracks = await _controller.getAudioTracks();
    _showTrackSelectionDialog('Audio Track', tracks, (id) async {
      await _controller.setAudioTrack(id);
    });
  }

  Future<void> _changeSubtitleTrack() async {
    final tracks = await _controller.getSubtitleTracks();
    _showTrackSelectionDialog('Subtitle', tracks, (id) async {
      await _controller.setSubtitleTrack(id);
    });
  }



  void _toggleFullscreen() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Toggling Player View Mode...')));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        children: [
          Positioned.fill(
            child: VlcPlayer(controller: _controller, backgroundColor: Colors.black, fit: _currentFit),
          ),
          if (_errorText != null)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Text('VLC playback error:\n$_errorText', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              ),
            ),
          if (_showControls)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            widget.channelName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 4.0, color: Colors.black)]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(icon: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white), onPressed: _togglePlayPause),
                          IconButton(icon: const Icon(Icons.aspect_ratio, color: Colors.white), tooltip: 'Aspect Ratio', onPressed: _cycleAspectRatio),
                          IconButton(icon: const Icon(Icons.audiotrack, color: Colors.white), tooltip: 'Audio Track', onPressed: _changeAudioTrack),
                          IconButton(icon: const Icon(Icons.subtitles, color: Colors.white), tooltip: 'Subtitles', onPressed: _changeSubtitleTrack),
                          IconButton(
                            icon: Icon(widget.isFavorited ? Icons.star : Icons.star_border, color: widget.isFavorited ? ShroudyColors.goldText : Colors.white),
                            tooltip: 'Favorite',
                            onPressed: widget.onFavToggle,
                          ),
                          IconButton(icon: const Icon(Icons.fullscreen, color: Colors.white), tooltip: 'Fullscreen', onPressed: _toggleFullscreen),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
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
