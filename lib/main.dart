import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart'; // 📺 Added Native LibVLC

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp
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

  ChannelItem({required this.name, required this.logoUrl, required this.streamUrl, required this.category});
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
          "https://raw.githubusercontent.com/shroudybuoy/TV-Channels/refs/heads/main/channel%20playlist.m3u"));
      
      if (response.statusCode == 200) {
        final lines = response.body.split('\n');
        String currentName = '';
        String currentLogo = '';
        String currentCategory = 'Uncategorized';
        final categoriesSet = <String>{};

        for (var line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;

          if (trimmed.toUpperCase().startsWith('#EXTINF:')) {
            currentName = _extractAttribute(trimmed, 'tvg-name');
            if (currentName.isEmpty) {
              final commaIndex = trimmed.lastIndexOf(',');
              if (commaIndex >= 0) currentName = trimmed.substring(commaIndex + 1).trim();
            }
            currentLogo = _extractAttribute(trimmed, 'logo');
            currentCategory = _extractAttribute(trimmed, 'group-title');
            if (currentCategory.isEmpty) currentCategory = 'Uncategorized';
            categoriesSet.add(currentCategory);
          } else if (!trimmed.startsWith('#')) {
            if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
              _allChannelsList.add(ChannelItem(
                name: currentName.isEmpty ? "Unknown Channel" : currentName,
                logoUrl: currentLogo,
                streamUrl: trimmed,
                category: currentCategory,
              ));
              currentName = '';
              currentLogo = '';
            }
          }
        }
        
        final prefs = await SharedPreferences.getInstance();
        final savedFavs = prefs.getStringList('favorite_names') ?? [];

        setState(() {
          _favoritesList.addAll(savedFavs);
          _categoriesList.addAll(categoriesSet.toList()..sort());
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  String _extractAttribute(String line, String attributeName) {
    final regExp = RegExp('$attributeName\\s*=\\s*"([^"]*)"', case_sensitive: false);
    final match = regExp.firstMatch(line);
    return match?.group(1)?.trim() ?? '';
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
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

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
      body: isLandscape && _currentChannel != null
          ? _buildImmersiveLandscapePlayer()
          : _buildStandardTwoPaneLayout(filteredChannels),
    );
  }

  Widget _buildStandardTwoPaneLayout(List<ChannelItem> channels) {
    return Column(
      children: [
        if (_currentChannel != null) _buildEmbeddedPortraitPlayerView(),
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
            itemBuilder: (context, index) {
              final channel = channels[index];
              return _buildChannelItemCard(channel);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryAndSearchHeaderRow() {
    final finalCategories = ['All', if (_favoritesList.isNotEmpty) '★ Favorites'] + 
        _categoriesList.sublist(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              hintText: "Search channels...",
              hintStyle: const TextStyle(color: Colors.grey),
              fillColor: ShroudyColors.cardNavyBg,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildChannelItemCard(ChannelItem channel) {
    return Card(
      color: ShroudyColors.cardNavyBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      child: InkWell(
        onTap: () => setState(() => _currentChannel = channel),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: ShroudyColors.innerLogoBg,
                  width: double.infinity,
                  child: Image.network(channel.logoUrl, fit: BoxFit.contain, 
                    errorBuilder: (_, _, _) => const Icon(Icons.tv, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 6),
              Text(channel.name, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              const Text("● LIVE", style: TextStyle(color: ShroudyColors.liveIndicator, fontSize: 8, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmbeddedPortraitPlayerView() {
    return Container(
      color: Colors.black,
      width: double.infinity,
      height: 240,
      child: VideoCanvasPlayerLayer(
        key: ValueKey(_currentChannel!.streamUrl),
        streamUrl: _currentChannel!.streamUrl,
        channelName: _currentChannel!.name,
        isFavorited: _favoritesList.contains(_currentChannel!.name),
        onFavToggle: () => _toggleFavorite(_currentChannel!.name),
        onClose: () => setState(() => _currentChannel = null),
      ),
    );
  }

  Widget _buildImmersiveLandscapePlayer() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: VideoCanvasPlayerLayer(
        key: ValueKey(_currentChannel!.streamUrl),
        streamUrl: _currentChannel!.streamUrl,
        channelName: _currentChannel!.name,
        isFavorited: _favoritesList.contains(_currentChannel!.name),
        onFavToggle: () => _toggleFavorite(_currentChannel!.name),
        onClose: () => setState(() => _currentChannel = null),
      ),
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
    required this.onClose
  });

  @override
  State<VideoCanvasPlayerLayer> createState() => _VideoCanvasPlayerLayerState();
}

class _VideoCanvasPlayerLayerState extends State<VideoCanvasPlayerLayer> {
  late VlcPlayerController _vlcViewController;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // Mount and initialize the raw LibVLC C++ core decoder with network proxies
    _vlcViewController = VlcPlayerController.network(
      widget.streamUrl,
      hwAcc: HwAcc.full, // Active hardware decoding matching Windows client
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([VlcAdvancedOptions.networkCaching(1500)]),
        http: VlcHttpOptions(['--http-user-agent=VLC/3.0.16 Mozilla/5.0']),
      ),
      autoPlay: true,
    );
    
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _vlcViewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        children: [
          Positioned.fill(
            child: VlcPlayer(
              controller: _vlcViewController,
              aspectRatio: 16 / 9,
              placeholder: const Center(
                child: CircularProgressIndicator(color: ShroudyColors.primaryRed),
              ),
            ),
          ),
          if (_showControls)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent, Colors.black87],
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: widget.onClose,
                        ),
                        Text(
                          widget.channelName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            widget.isFavorited ? Icons.star : Icons.star_border,
                            color: widget.isFavorited ? ShroudyColors.goldText : Colors.white,
                          ),
                          onPressed: widget.onFavToggle,
                        ),
                      ],
                    ),
                    IconButton(
                      icon: Icon(
                        _vlcViewController.value.isPlaying ? Icons.pause : Icons.play_arrow, 
                        color: Colors.white, 
                        size: 48
                      ),
                      onPressed: () async {
                        if (_vlcViewController.value.isPlaying) {
                          await _vlcViewController.pause();
                        } else {
                          await _vlcViewController.play();
                        }
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
