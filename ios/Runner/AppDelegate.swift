import AVFoundation
import AVKit
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PictureInPictureBridge") {
      PictureInPictureBridge.register(with: registrar)
    }
  }
}

/// Picture in Picture for the VLC player.
///
/// MobileVLCKit draws into a plain UIView and never hands out decoded frames, while
/// AVPictureInPictureController only accepts an AVPlayerLayer or an
/// AVSampleBufferDisplayLayer, so PiP cannot be attached to VLC's surface at all.
/// Instead, while a channel is playing, this keeps a second silent AVPlayer on the
/// same URL underneath the Flutter view and lets iOS promote that layer to a PiP
/// window when the app goes to the background. The shipped playlist is almost entirely
/// HLS, which AVPlayer opens natively; a URL it cannot play just means no PiP for that
/// channel, which is the behaviour the app had before.
///
/// Deliberately kept inside AppDelegate.swift: every other source file has to be
/// listed in project.pbxproj, and hand-editing that file is the easiest way to break
/// a build that nobody can run locally.
final class PictureInPictureBridge: NSObject, FlutterPlugin, FlutterStreamHandler,
  AVPictureInPictureControllerDelegate
{
  private static var instance: PictureInPictureBridge?

  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var controller: AVPictureInPictureController?
  private var statusTimer: Timer?
  private var eventSink: FlutterEventSink?
  private var armedURL: URL?

  // MARK: - FlutterPlugin

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PictureInPictureBridge()
    instance.observeNotifications()
    self.instance = instance

    let channel = FlutterMethodChannel(
      name: "shroudy_tv/pip", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)

    let events = FlutterEventChannel(
      name: "shroudy_tv/pip/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "arm":
      let args = call.arguments as? [String: Any]
      arm(url: args?["url"] as? String, userAgent: args?["userAgent"] as? String)
      result(statusPayload())
    case "disarm":
      disarm()
      result(statusPayload())
    case "status":
      result(statusPayload())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    DispatchQueue.main.async { events(self.statusPayload()) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Arming

  /// Prepare the hidden player for one stream. Calling this again with the same URL
  /// does nothing, so a channel switch is the only thing that tears it down.
  private func arm(url: String?, userAgent: String?) {
    guard let target = URL(string: url ?? ""), target.scheme != nil else {
      emit(["state": "invalid_url", "url": url ?? ""])
      return
    }
    if target == armedURL, player != nil { return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      // iPads always say yes; an iPhone without iCloud+ says no, and the app then
      // behaves exactly as it did before PiP was added.
      emit(["state": "unsupported", "url": target.absoluteString])
      return
    }

    disarm()

    var options: [String: Any]?
    if let userAgent, !userAgent.isEmpty {
      // The documented CFDictionary key for AVURLAsset; the Swift constant of the
      // same name is not guaranteed to be imported, the string is.
      options = ["AVURLAssetHTTPUserAgentKey": userAgent]
    }
    let asset = AVURLAsset(url: target, options: options)
    let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    // VLC is the player the user hears while the app is in front, so this copy is
    // muted until PiP actually takes over.
    newPlayer.isMuted = true

    guard let window = Self.frontWindow() else {
      emit(["state": "no_window", "url": target.absoluteString])
      return
    }

    let layer = AVPlayerLayer(player: newPlayer)
    layer.videoGravity = .resizeAspect
    layer.frame = window.bounds
    // Underneath Flutter's own view: added on top it would cover the app.
    window.layer.insertSublayer(layer, at: 0)

    // The initializer is failable: it returns nil when the device does not
    // support PiP at all.
    guard let pip = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      emit(["state": "no_pip_controller", "url": target.absoluteString])
      return
    }
    pip.delegate = self
    if #available(iOS 15.0, *) {
      // This is what turns "pressed the home button" into a PiP window without the app
      // having to ask at a moment when it is already being suspended.
      pip.canStartPictureInPictureAutomaticallyFromInline = true
    }

    armedURL = target
    player = newPlayer
    playerLayer = layer
    controller = pip

    // Background playback needs an active playback session. VLC normally keeps one
    // open already, so failing here is not worth aborting over.
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)

    // Kept running, muted, for the whole time the channel is open: that is what
    // makes the PiP window show a picture the instant the app leaves the screen
    // instead of a black box while a fresh HLS buffer fills. The cost is a second
    // copy of the stream being downloaded while you watch.
    newPlayer.play()
    watchStatus()
    emit(statusPayload())
  }

  private func disarm() {
    statusTimer?.invalidate()
    statusTimer = nil
    if #available(iOS 15.0, *) {
      controller?.canStartPictureInPictureAutomaticallyFromInline = false
    }
    controller?.delegate = nil
    controller = nil
    player?.isMuted = true
    player?.pause()
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    player = nil
    armedURL = nil
  }

  /// AVPlayer reports an unusable IPTV URL only after several seconds of buffering,
  /// and the difference between "not yet" and "never" is the whole debug story for a
  /// build that cannot be run by hand, so the status is polled and forwarded rather
  /// than assumed. Polling instead of KVO keeps this file free of key-path strings.
  private func watchStatus() {
    statusTimer?.invalidate()
    var ticks = 0
    statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
      guard let self else { return }
      ticks += 1
      let payload = self.statusPayload()
      self.emit(payload)
      if payload["itemStatus"] as? Int == 2 || ticks > 30 {
        timer.invalidate()
        if self.statusTimer === timer { self.statusTimer = nil }
      }
    }
  }

  private func statusPayload() -> [String: Any] {
    return [
      "state": player == nil ? "idle" : "armed",
      "url": armedURL?.absoluteString ?? "",
      // AVPlayerItem.Status: 0 unknown, 1 failed, 2 ready. Failed loads carry an
      // NSError that is only visible from here.
      "itemStatus": player?.currentItem?.status.rawValue ?? -1,
      "error": player?.currentItem?.error?.localizedDescription ?? "",
      "canStart": controller?.isPictureInPicturePossible ?? false,
      "active": controller?.isPictureInPictureActive ?? false,
    ]
  }

  private func emit(_ payload: [String: Any]) {
    guard let eventSink else { return }
    DispatchQueue.main.async { self.eventSink?(payload) }
  }

  private static func frontWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
    }
    return scenes.first?.windows.first
  }

  // MARK: - Background transition

  private func observeNotifications() {
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(becameActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(enteredBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  @objc private func becameActive() {
    // Rotating while backgrounded leaves the inline layer with the old bounds.
    guard player != nil, let window = Self.frontWindow() else { return }
    playerLayer?.frame = window.bounds
  }

  @objc private func enteredBackground() {
    guard let controller, !controller.isPictureInPictureActive else { return }
    // Nothing to show: AVPlayer could not open the stream, or iOS refused the hidden
    // layer. Say so instead of leaving a silent PiP-less app as a mystery.
    emit(statusPayload())
  }

  // MARK: - AVPictureInPictureControllerDelegate

  // These are optional requirements of an Objective-C protocol, so they are
  // marked @objc explicitly rather than left to inference.
  @objc func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // The app is on its way out and Dart pauses VLC when it hears PiP started, so
    // this copy takes over the sound from here. The inline layer stays mounted:
    // hiding the layer that PiP is reading from is a reliable way to end the session.
    player?.isMuted = false
    player?.volume = 1
    player?.play()
    emit(statusPayload())
  }

  @objc func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    emit(statusPayload())
  }

  @objc func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    emit(statusPayload())
  }

  @objc func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // Back in the app: VLC is audible again, so go quiet but keep buffering, which is
    // what makes the next background transition show a picture immediately.
    player?.isMuted = true
    player?.volume = 0
    player?.play()
    emit(statusPayload())
  }
}
