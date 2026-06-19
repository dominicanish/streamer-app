import ExpoModulesCore
import AVFoundation
import os

// ─────────────────────────────────────────────────────────────────────────────
// Módulo Expo: expone connect/disconnect/setBufferMs y eventos onStats/onLog.
// ─────────────────────────────────────────────────────────────────────────────
public class AudioStreamerModule: Module {
  private let streamer = AudioStreamer()

  public func definition() -> ModuleDefinition {
    Name("AudioStreamer")
    Events("onStats", "onLog")

    OnCreate {
      self.streamer.onLog = { [weak self] message, level in
        self?.sendEvent("onLog", ["message": message, "level": level])
      }
      self.streamer.onStats = { [weak self] stats in
        self?.sendEvent("onStats", stats)
      }
    }

    Function("connect") { (url: String, bufferMs: Double) in
      self.streamer.connect(urlString: url, bufferMs: bufferMs)
    }

    Function("disconnect") {
      self.streamer.disconnect()
    }

    Function("setBufferMs") { (ms: Double) in
      self.streamer.setBufferMs(ms)
    }

    OnDestroy {
      self.streamer.disconnect()
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AudioStreamer: WebSocket -> ring buffer -> AVAudioEngine (AVAudioSourceNode).
// El AVAudioEngine reproduce a 48 kHz y convierte a la tasa del hardware solo.
// ─────────────────────────────────────────────────────────────────────────────
final class AudioStreamer: NSObject, URLSessionWebSocketDelegate {

  var onLog: ((String, String) -> Void)?
  var onStats: (([String: Any]) -> Void)?

  // Audio
  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private let sampleRate: Double = 48000
  private let channels = 2

  // Ring buffer (float interleaved L,R). SPSC; secciones críticas mínimas.
  private let capFrames = 48000 * 4          // 4 s
  private var ring: [Float]
  private var writeIdx: Int = 0              // en frames
  private var readIdx: Int = 0              // en frames
  private var lock = os_unfair_lock()
  private var playing = false
  private var targetFrames: Int = Int(48000 * 0.1)

  // WebSocket
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var isConnected = false

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
    disconnect()
    guard let url = URL(string: urlString) else {
      onLog?("URL inválida: \(urlString)", "err"); return
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

    if !startEngine() { return }

    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = true
    let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    let t = s.webSocketTask(with: url)
    session = s
    task = t
    isConnected = true
    writeIdx = 0; readIdx = 0; playing = false; underruns = 0
    t.resume()
    receiveLoop()
    startStatsTimer()
    onLog?("Conectando a \(urlString)…", "info")
  }

  func disconnect() {
    isConnected = false
    statsTimer?.cancel(); statsTimer = nil
    task?.cancel(with: .goingAway, reason: nil); task = nil
    session?.invalidateAndCancel(); session = nil
    if engine.isRunning { engine.stop() }
    if let n = sourceNode { engine.detach(n); sourceNode = nil }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  func setBufferMs(_ ms: Double) {
    let m = max(20.0, min(1000.0, ms))
    targetFrames = Int(sampleRate * m / 1000.0)
  }

  // ── Motor de audio ───────────────────────────────────────────────────────────
  private func startEngine() -> Bool {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: AVAudioChannelCount(channels),
                                     interleaved: false) else {
      onLog?("No se pudo crear el formato de audio", "err"); return false
    }

    let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
      guard let self = self else { return noErr }
      return self.render(frameCount: Int(frameCount), abl: audioBufferList)
    }
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    sourceNode = node

    do {
      try engine.start()
    } catch {
      onLog?("No se pudo iniciar el motor: \(error.localizedDescription)", "err")
      return false
    }
    return true
  }

  // Callback de render (hilo de audio en tiempo real).
  private func render(frameCount n: Int, abl audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let outL = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let outR = (abl.count > 1 ? abl[1].mData! : abl[0].mData!).assumingMemoryBound(to: Float.self)

    os_unfair_lock_lock(&lock)
    let available = writeIdx - readIdx

    if !playing {
      if available >= targetFrames {
        playing = true
      } else {
        for i in 0..<n { outL[i] = 0; outR[i] = 0 }
        os_unfair_lock_unlock(&lock)
        return noErr
      }
    }

    // Recorte de deriva
    let maxBuf = targetFrames * 2 + Int(sampleRate * 0.1)
    if available > maxBuf { readIdx = writeIdx - targetFrames }

    var produced = 0
    while produced < n {
      if readIdx >= writeIdx {
        for i in produced..<n { outL[i] = 0; outR[i] = 0 }
        playing = false
        underruns += 1
        break
      }
      let idx = (readIdx % capFrames) * 2
      outL[produced] = ring[idx]
      outR[produced] = ring[idx + 1]
      readIdx += 1
      produced += 1
    }
    os_unfair_lock_unlock(&lock)
    return noErr
  }

  // ── WebSocket ────────────────────────────────────────────────────────────────
  private func receiveLoop() {
    task?.receive { [weak self] result in
      guard let self = self, self.isConnected else { return }
      switch result {
      case .failure(let err):
        self.onLog?("WS cerrado: \(err.localizedDescription)", "warn")
        return
      case .success(let message):
        switch message {
        case .data(let data): self.handlePCM(data)
        case .string(let text): self.handleControl(text)
        @unknown default: break
        }
        if self.isConnected { self.receiveLoop() }
      }
    }
  }

  private func handlePCM(_ data: Data) {
    let sampleCount = data.count / 2
    let frames = sampleCount / channels
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
        ring[idx] = l
        ring[idx + 1] = r
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
      deviceName = obj["device"] as? String ?? ""
      mutedPc = obj["mutedPc"] as? Bool ?? false
      onLog?("Servidor: \(deviceName)", "ok")
    case "stats":
      serverPeak = Float(obj["serverPeak"] as? Double ?? 0)
    case "flow":
      flow = obj["active"] as? Bool ?? false
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
    let kbps = dt > 0 ? Int(Double(bytesWindow) * 8.0 / dt / 1000.0) : 0
    bytesWindow = 0
    lastBitrateAt = now

    os_unfair_lock_lock(&lock)
    let bufferMs = Double(writeIdx - readIdx) / sampleRate * 1000.0
    os_unfair_lock_unlock(&lock)

    onStats?([
      "connected": isConnected,
      "device": deviceName,
      "bufferMs": max(0, bufferMs),
      "underruns": underruns,
      "bitrateKbps": kbps,
      "clientPeak": Double(clientPeak),
      "serverPeak": Double(serverPeak),
      "mutedPc": mutedPc,
      "flow": flow,
    ])
  }

  // ── Delegate ──────────────────────────────────────────────────────────────────
  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didOpenWithProtocol protocol: String?) {
    onLog?("WebSocket abierto", "ok")
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    onLog?("WebSocket cerrado", "warn")
  }
}
