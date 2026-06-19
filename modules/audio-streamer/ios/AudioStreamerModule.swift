import ExpoModulesCore
import AVFoundation
import MediaPlayer
import UIKit
import os

// ─────────────────────────────────────────────────────────────────────────────
// Módulo Expo: connect/disconnect/setBufferMs + eventos. (Sin pausa: el teléfono
// solo reproduce lo que el PC envía.)
// ─────────────────────────────────────────────────────────────────────────────
public class AudioStreamerModule: Module {
  private let streamer = AudioStreamer()

  public func definition() -> ModuleDefinition {
    Name("AudioStreamer")
    Events("onStats", "onLog", "onArtwork")

    OnCreate {
      self.streamer.onLog = { [weak self] message, level in
        self?.sendEvent("onLog", ["message": message, "level": level])
      }
      self.streamer.onStats = { [weak self] stats in
        self?.sendEvent("onStats", stats)
      }
      self.streamer.onArtwork = { [weak self] dataUri in
        self?.sendEvent("onArtwork", ["dataUri": dataUri])
      }
    }

    Function("connect") { (url: String, bufferMs: Double) in
      self.streamer.connect(urlString: url, bufferMs: bufferMs)
    }
    Function("disconnect") { self.streamer.disconnect() }
    Function("setBufferMs") { (ms: Double) in self.streamer.setBufferMs(ms) }

    OnDestroy { self.streamer.disconnect() }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AudioStreamer: WebSocket -> ring buffer -> AVAudioEngine, + Now Playing (solo
// display). Handshake: no se reporta "connected" hasta recibir 'hello'; timeout
// si el servidor no responde.
// ─────────────────────────────────────────────────────────────────────────────
final class AudioStreamer: NSObject, URLSessionWebSocketDelegate {

  var onLog: ((String, String) -> Void)?
  var onStats: (([String: Any]) -> Void)?
  var onArtwork: ((String) -> Void)?

  private let handshakeTimeout: TimeInterval = 6.0

  // Audio
  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private let sampleRate: Double = 48000
  private let channels = 2

  // Ring buffer (float interleaved L,R). SPSC, secciones críticas mínimas.
  private let capFrames = 48000 * 4
  private var ring: [Float]
  private var writeIdx = 0
  private var readIdx = 0
  private var lock = os_unfair_lock()
  private var playing = false
  private var targetFrames = Int(48000 * 0.1)

  // WebSocket / estado de conexión
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var receiving = false                 // ¿seguimos en el bucle de recepción?
  private var state = "disconnected"            // disconnected | connecting | connected | failed
  private var handshakeTimer: DispatchSourceTimer?
  private var commandsConfigured = false

  // Now Playing (solo display)
  private var npTitle = ""
  private var npArtist = ""
  private var npApp = ""
  private var npArtwork: MPMediaItemArtwork?

  // Stats
  private var underruns = 0
  private var bytesWindow = 0
  private var clientPeak: Float = 0
  private var serverPeak: Float = 0
  private var mutedPc = false
  private var flow = false
  private var deviceName = ""
  private var statsTimer: DispatchSourceTimer?
  private var lastBitrateAt = Date()

  override init() {
    ring = [Float](repeating: 0, count: capFrames * 2)
    super.init()
  }

  // ── API ────────────────────────────────────────────────────────────────────
  func connect(urlString: String, bufferMs: Double) {
    teardown()
    guard let url = URL(string: urlString) else {
      setState("failed"); onLog?("URL inválida: \(urlString)", "err"); return
    }
    setBufferMs(bufferMs)

    do {
      let sess = AVAudioSession.sharedInstance()
      try sess.setCategory(.playback, mode: .default, options: [])
      try sess.setPreferredSampleRate(sampleRate)
      try sess.setPreferredIOBufferDuration(0.01)
      try sess.setActive(true)
    } catch {
      onLog?("AVAudioSession error: \(error.localizedDescription)", "warn")
    }

    if !startEngine() { setState("failed"); return }

    npTitle = ""; npArtist = ""; npApp = ""; npArtwork = nil
    configureRemoteCommands()
    writeIdx = 0; readIdx = 0; playing = false; underruns = 0

    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = false
    cfg.timeoutIntervalForRequest = handshakeTimeout
    let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    let t = s.webSocketTask(with: url)
    session = s; task = t
    receiving = true
    setState("connecting")
    onLog?("Conectando a \(urlString)…", "info")
    t.resume()
    receiveLoop()
    startStatsTimer()
    startHandshakeTimeout()
  }

  func disconnect() {
    teardown()
    setState("disconnected")
  }

  // Cierra todo SIN tocar el estado (lo fija quien llama).
  private func teardown() {
    receiving = false
    handshakeTimer?.cancel(); handshakeTimer = nil
    statsTimer?.cancel(); statsTimer = nil
    task?.cancel(with: .goingAway, reason: nil); task = nil
    session?.invalidateAndCancel(); session = nil
    if engine.isRunning { engine.stop() }
    if let n = sourceNode { engine.detach(n); sourceNode = nil }
    DispatchQueue.main.async {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  func setBufferMs(_ ms: Double) {
    targetFrames = Int(sampleRate * max(20.0, min(1000.0, ms)) / 1000.0)
  }

  private func setState(_ s: String) {
    state = s
    emitStats()
  }

  private func startHandshakeTimeout() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + handshakeTimeout)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      if self.state == "connecting" {
        self.onLog?("Sin respuesta del servidor (timeout). ¿IP correcta y servidor encendido?", "err")
        self.teardown()
        self.setState("failed")
      }
    }
    handshakeTimer = timer
    timer.resume()
  }

  // ── Now Playing (solo display) ───────────────────────────────────────────────
  private func configureRemoteCommands() {
    if commandsConfigured { return }
    commandsConfigured = true
    // Sin controles: el teléfono solo refleja lo que el PC envía.
    let cc = MPRemoteCommandCenter.shared()
    for cmd in [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand,
                cc.nextTrackCommand, cc.previousTrackCommand,
                cc.changePlaybackPositionCommand, cc.seekForwardCommand,
                cc.seekBackwardCommand, cc.skipForwardCommand, cc.skipBackwardCommand] {
      cmd.isEnabled = false
    }
  }

  private func updateNowPlaying() {
    let title = npTitle.isEmpty ? "Audio del PC" : npTitle
    let subtitle = !npArtist.isEmpty ? npArtist : npApp
    let art = npArtwork
    DispatchQueue.main.async {
      var info: [String: Any] = [:]
      info[MPMediaItemPropertyTitle] = title
      if !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
      if let art = art { info[MPMediaItemPropertyArtwork] = art }
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      MPNowPlayingInfoCenter.default().playbackState = .playing
    }
  }

  private func setArtwork(_ b64: String) {
    if b64.isEmpty { npArtwork = nil; onArtwork?(""); return }
    guard let data = Data(base64Encoded: b64), let img = UIImage(data: data) else {
      npArtwork = nil; onArtwork?(""); return
    }
    npArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    let isPng = data.count > 4 && data[0] == 0x89 && data[1] == 0x50
    onArtwork?("data:\(isPng ? "image/png" : "image/jpeg");base64,\(b64)")
  }

  // ── Motor de audio ───────────────────────────────────────────────────────────
  private func startEngine() -> Bool {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                     channels: AVAudioChannelCount(channels), interleaved: false) else {
      onLog?("No se pudo crear el formato de audio", "err"); return false
    }
    let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
      guard let self = self else { return noErr }
      return self.render(frameCount: Int(frameCount), abl: abl)
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    sourceNode = node
    do { try engine.start() } catch {
      onLog?("No se pudo iniciar el motor: \(error.localizedDescription)", "err"); return false
    }
    return true
  }

  private func render(frameCount n: Int, abl audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let outL = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let outR = (abl.count > 1 ? abl[1].mData! : abl[0].mData!).assumingMemoryBound(to: Float.self)

    os_unfair_lock_lock(&lock)
    let available = writeIdx - readIdx
    if !playing {
      if available >= targetFrames { playing = true }
      else { for i in 0..<n { outL[i] = 0; outR[i] = 0 }; os_unfair_lock_unlock(&lock); return noErr }
    }
    let maxBuf = targetFrames * 2 + Int(sampleRate * 0.1)
    if available > maxBuf { readIdx = writeIdx - targetFrames }

    var produced = 0
    while produced < n {
      if readIdx >= writeIdx {
        for i in produced..<n { outL[i] = 0; outR[i] = 0 }
        playing = false; underruns += 1; break
      }
      let idx = (readIdx % capFrames) * 2
      outL[produced] = ring[idx]; outR[produced] = ring[idx + 1]
      readIdx += 1; produced += 1
    }
    os_unfair_lock_unlock(&lock)
    return noErr
  }

  // ── WebSocket ────────────────────────────────────────────────────────────────
  private func receiveLoop() {
    task?.receive { [weak self] result in
      guard let self = self, self.receiving else { return }
      switch result {
      case .failure(let err):
        if self.state == "connecting" {
          self.onLog?("No se pudo conectar: \(err.localizedDescription)", "err")
          self.teardown(); self.setState("failed")
        } else if self.state == "connected" {
          self.onLog?("Conexión perdida: \(err.localizedDescription)", "warn")
          self.teardown(); self.setState("disconnected")
        }
        return
      case .success(let message):
        switch message {
        case .data(let data): self.handlePCM(data)
        case .string(let text): self.handleControl(text)
        @unknown default: break
        }
        if self.receiving { self.receiveLoop() }
      }
    }
  }

  private func handlePCM(_ data: Data) {
    let frames = (data.count / 2) / channels
    if frames == 0 { return }
    var peak: Float = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let i16 = raw.bindMemory(to: Int16.self)
      os_unfair_lock_lock(&lock)
      var w = writeIdx
      for f in 0..<frames {
        let l = Float(Int16(littleEndian: i16[f * 2])) / 32768.0
        let r = Float(Int16(littleEndian: i16[f * 2 + 1])) / 32768.0
        let idx = (w % capFrames) * 2
        ring[idx] = l; ring[idx + 1] = r
        w += 1
        let a = abs(l); if a > peak { peak = a }
      }
      writeIdx = w
      if writeIdx - readIdx > capFrames { readIdx = writeIdx - targetFrames }
      os_unfair_lock_unlock(&lock)
    }
    clientPeak = peak
    bytesWindow += data.count
  }

  private func handleControl(_ text: String) {
    guard let d = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let type = obj["type"] as? String else { return }
    switch type {
    case "hello":
      // Handshake confirmado: ahora sí estamos conectados de verdad.
      deviceName = obj["device"] as? String ?? ""
      mutedPc = obj["mutedPc"] as? Bool ?? false
      handshakeTimer?.cancel(); handshakeTimer = nil
      if state != "connected" { onLog?("Conectado: \(deviceName)", "ok") }
      configureRemoteCommands()
      updateNowPlaying()
      setState("connected")
    case "stats":
      serverPeak = Float(obj["serverPeak"] as? Double ?? 0)
    case "flow":
      flow = obj["active"] as? Bool ?? false
    case "nowplaying":
      npTitle = obj["title"] as? String ?? ""
      npArtist = obj["artist"] as? String ?? ""
      npApp = obj["app"] as? String ?? ""
      setArtwork(obj["artwork"] as? String ?? "")
      updateNowPlaying()
      emitStats()
    default: break
    }
  }

  // ── Stats hacia JS ────────────────────────────────────────────────────────────
  private func startStatsTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in self?.emitStats() }
    statsTimer = timer
    timer.resume()
  }

  private func emitStats() {
    let now = Date()
    let dt = now.timeIntervalSince(lastBitrateAt)
    let kbps = dt > 0.2 ? Int(Double(bytesWindow) * 8.0 / dt / 1000.0) : 0
    if dt > 0.5 { bytesWindow = 0; lastBitrateAt = now }

    os_unfair_lock_lock(&lock)
    let bufferMs = Double(writeIdx - readIdx) / sampleRate * 1000.0
    os_unfair_lock_unlock(&lock)

    onStats?([
      "state": state,
      "connected": state == "connected",
      "device": deviceName,
      "bufferMs": max(0, bufferMs),
      "underruns": underruns,
      "bitrateKbps": kbps,
      "clientPeak": Double(clientPeak),
      "serverPeak": Double(serverPeak),
      "mutedPc": mutedPc,
      "flow": flow,
      "npTitle": npTitle,
      "npArtist": npArtist,
      "npApp": npApp,
    ])
  }

  // ── Delegate ──────────────────────────────────────────────────────────────────
  func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
    onLog?("Socket abierto, esperando servidor…", "info")
  }
  func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    if state == "connecting" { teardown(); setState("failed") }
  }
}
