import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart half of the iOS Picture in Picture bridge implemented in
/// `ios/Runner/AppDelegate.swift`.
///
/// VLC renders video into its own surface, which iOS will not promote to a PiP
/// window, so the native side keeps a silent AVPlayer on the same stream and lets
/// the system show that when the app is backgrounded. All of the decisions happen
/// natively; this class only tells the player which stream to mirror, stops
/// mirroring it, and reports back when PiP starts or stops so VLC can hand the
/// audio over instead of playing a second copy of the same soundtrack.
class PictureInPicture {
  PictureInPicture._();

  static const MethodChannel _channel = MethodChannel('shroudy_tv/pip');
  static const EventChannel _events = EventChannel('shroudy_tv/pip/events');

  /// PiP is iOS-only here; the app has no Android target in this project and the
  /// native code is not compiled for anything else.
  static bool get isSupported => !kIsWeb && Platform.isIOS;

  /// Ask the native side to mirror [url]. Repeating the same URL is cheap: the
  /// bridge ignores it rather than tearing down a buffering player.
  static Future<void> arm(String url) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('arm', {'url': url});
    } catch (e) {
      debugPrint('PiP arm failed: $e');
    }
  }

  static Future<void> disarm() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('disarm');
    } catch (e) {
      debugPrint('PiP disarm failed: $e');
    }
  }

  /// One event per PiP state change, plus a few seconds of status polling after
  /// [arm] so a stream that AVPlayer cannot open is visible in the logs rather
  /// than silently missing.
  static Stream<PipStatus> get statuses =>
      _events.receiveBroadcastStream().map(_toStatus);

  static PipStatus _toStatus(Object? event) {
    final map = event is Map ? event : const {};
    return PipStatus(
      active: map['active'] == true,
      canStart: map['canStart'] == true,
      armed: map['state'] == 'armed',
      itemStatus: (map['itemStatus'] as num?)?.toInt() ?? -1,
      error: (map['error'] as String?) ?? '',
      url: (map['url'] as String?) ?? '',
    );
  }
}

/// Snapshot of the native bridge. [itemStatus] mirrors AVPlayerItem.Status:
/// 0 unknown, 1 failed, 2 ready to play.
class PipStatus {
  const PipStatus({
    required this.active,
    required this.canStart,
    required this.armed,
    required this.itemStatus,
    required this.error,
    required this.url,
  });

  final bool active;
  final bool canStart;
  final bool armed;
  final int itemStatus;
  final String error;
  final String url;

  /// AVPlayer could not open the stream, so this channel will never get a PiP
  /// window. Usually a non-HLS URL or a server that rejects AVPlayer's request.
  bool get failed => itemStatus == 1;

  @override
  String toString() =>
      'PipStatus(active: $active, canStart: $canStart, armed: $armed, '
      'itemStatus: $itemStatus, error: $error)';
}
