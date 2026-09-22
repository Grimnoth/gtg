// gtg-listen -- say a set out loud; this prints what you said.
//
// On-device speech, through the SpeechTranscriber framework macOS 26 ships.
// No API key, no network, no model to download by hand, and the audio never
// leaves the Mac. That last one is the reason this is not a web service: the
// microphone is always the most invasive thing a small tool can ask for, and
// the answer here is that nothing it hears is ever sent anywhere.
//
// It prints ONE line on stdout: the transcript, or nothing at all. Everything
// it wants to say to a person goes to stderr, so the caller can pipe stdout
// straight into `gtg` without filtering it.
//
//   gtg-listen                 listen on the default input
//   gtg-listen --list          the input devices, one per line
//   gtg-listen --device NAME   listen on that one
//   gtg-listen --max 30        never run longer than this
//
// It stops BY ITSELF. Requiring a second press to stop would double the
// friction this exists to remove, and a recorder you have to remember to stop
// is a recorder that runs for an hour in your pocket.

import AVFoundation
import CoreAudio
import Foundation
import Speech

// --- input devices ----------------------------------------------------------
// This is here because of a real failure, not for completeness: the default
// input on this Mac is a Scarlett 2i2 with nothing plugged into it, so the
// system default records silence at -71 dB. A speech tool that quietly hears
// nothing is the same shape as a reminder that quietly stops reminding, so the
// device is nameable and a silent one says so.

struct Device {
  let id: AudioDeviceID
  let name: String
}

private func deviceName(_ id: AudioDeviceID) -> String {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioObjectPropertyName,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  // Unmanaged, not a bare CFString: CoreAudio hands back a +1 reference, and
  // taking it as a plain CFString leaks it and warns about the object inside.
  var name: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
    let held = name
  else { return "" }
  return held.takeRetainedValue() as String
}

// A device with zero input channels is an output. Asking the stream
// configuration is the only honest test; the name tells you nothing.
private func hasInput(_ id: AudioDeviceID) -> Bool {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreamConfiguration,
    mScope: kAudioObjectPropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
  else { return false }
  let raw = UnsafeMutableRawPointer.allocate(
    byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
  defer { raw.deallocate() }
  guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
  let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
  return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

func inputDevices() -> [Device] {
  var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  let system = AudioObjectID(kAudioObjectSystemObject)
  guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
  guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
  return ids.filter(hasInput)
    .map { Device(id: $0, name: deviceName($0)) }
    // macOS builds a transient aggregate whenever something opens the default
    // device, and it comes and goes. Left in, it appears between a listing
    // and a pick and shifts every row number after it, so `gtg mic 3` chooses
    // a different microphone than the one that was on line 3 a moment ago.
    // Nobody can select it on purpose; an aggregate you MADE has your name on
    // it and is untouched.
    .filter { !$0.name.hasPrefix("CADefaultDeviceAggregate") && !$0.name.isEmpty }
}

// --- plumbing ---------------------------------------------------------------

private func say(_ s: String) {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// Two thresholds, because they answer two different questions.
//
// SPEECH_DB is "is someone talking", and it decides when a pause ends the
// recording. These are RMS over a buffer, not peak samples: a webcam
// microphone across a desk measured -48 dB RMS on speech that peaked at -11,
// so a threshold set by peak intuition stops the recording while you speak.
//
// DEAD_DB is "is this device connected to anything", and it decides whether to
// blame the input device. A Scarlett with nothing plugged in sits at -71 dB
// and a disabled microphone at -91, both far below any room.
private let SPEECH_DB: Float = -52
private let DEAD_DB: Float = -62

// EVERY channel, not channel 0.
//
// The Scarlett 2i2 presents four input channels: two instrument inputs and two
// loopback. Nothing is plugged into the first one, so judging the device by
// channel 0 reported a flat -59 dB noise floor while the room was being spoken
// to -- and "wrong input device" was printed about a device that could hear
// perfectly well. The loudest channel is the one that answers the question.
private func level(_ buf: AVAudioPCMBuffer) -> Float {
  guard let chans = buf.floatChannelData, buf.frameLength > 0 else { return -160 }
  var loudest: Float = -160
  for c in 0..<Int(buf.format.channelCount) {
    let ch = chans[c]
    var sum: Float = 0
    for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
    let rms = (sum / Float(buf.frameLength)).squareRoot()
    if rms > 0 { loudest = max(loudest, 20 * log10(rms)) }
  }
  return loudest
}

// Shared between the audio tap, which runs on its own thread, and the waiting
// loop. A lock rather than a bare var: the tap fires every few milliseconds.
final class Heard: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var lastLoud = Date.distantPast
  private var peak: Float = -160

  func note(_ db: Float) {
    lock.lock()
    defer { lock.unlock() }
    if db > peak { peak = db }
    if db > SPEECH_DB {
      started = true
      lastLoud = Date()
    }
  }

  var state: (started: Bool, quietFor: TimeInterval, peak: Float) {
    lock.lock()
    defer { lock.unlock() }
    return (started, Date().timeIntervalSince(lastLoud), peak)
  }
}

// Ctrl-C, or a second press of the hotkey, finishes the transcript rather than
// throwing it away. Stopping should never lose what you already said.
final class Stopped: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

@main
struct Main {
  static func main() async {
    var wanted: String?
    var maxSecs = 20.0
    let debug = ProcessInfo.processInfo.environment["GTG_LISTEN_DEBUG"] != nil
    var args = Array(CommandLine.arguments.dropFirst())

    while let a = args.first {
      args.removeFirst()
      switch a {
      case "--list":
        for d in inputDevices() { print(d.name) }
        exit(0)
      case "--device":
        wanted = args.isEmpty ? nil : args.removeFirst()
      case "--max":
        maxSecs = args.isEmpty ? maxSecs : (Double(args.removeFirst()) ?? maxSecs)
      default:
        say("gtg-listen: unknown option \(a)")
        exit(2)
      }
    }

    let transcriber = SpeechTranscriber(
      locale: Locale(identifier: "en-US"),
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [])

    // ASK FIRST, and only install when something is actually missing.
    //
    // Requesting the installation unconditionally cost most of a second on
    // every single launch and printed "installing the speech model" every
    // time, long after it was installed. That second is not a tidiness
    // problem: it is a second of a person talking into a microphone that is
    // not open yet, and the front of the sentence is gone for good. "I just
    // did 5 Bulgarian split squats" reached the log as "squats".
    let t0 = Date()
    if debug { say(String(format: "+%.0fms transcriber built", Date().timeIntervalSince(t0) * 1000)) }
    let status = await AssetInventory.status(forModules: [transcriber])
    if debug { say(String(format: "+%.0fms asset status = \(status)", Date().timeIntervalSince(t0) * 1000)) }
    if status != .installed {
      say("installing the speech model (once)...")
      if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try? await req.downloadAndInstall()
      }
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if debug { say(String(format: "+%.0fms analyzer", Date().timeIntervalSince(t0) * 1000)) }
    defer { if debug { say("(exiting)") } }
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else {
      say("gtg-listen: no usable audio format")
      exit(1)
    }

    if debug { say(String(format: "+%.0fms bestAvailableAudioFormat", Date().timeIntervalSince(t0) * 1000)) }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if debug { say(String(format: "+%.0fms inputNode", Date().timeIntervalSince(t0) * 1000)) }

    if let wanted {
      // Exact, then prefix, then substring, and each tier must match exactly
      // ONE device -- the same three tiers resolve_movement uses, and the same
      // rule about ties. Two identical webcams present two devices with one
      // name, and picking the first of them would have recorded from the
      // wrong one while reporting the name you asked for. An ambiguous name
      // is a question, not a guess.
      let all = inputDevices()
      let want = wanted.lowercased()
      let tiers = [
        all.filter { $0.name.lowercased() == want },
        all.filter { $0.name.lowercased().hasPrefix(want) },
        all.filter { $0.name.lowercased().contains(want) },
      ]
      guard let tier = tiers.first(where: { !$0.isEmpty }) else {
        say("gtg-listen: no input device matching \(wanted). Try: gtg mic")
        exit(1)
      }
      guard tier.count == 1, let hit = tier.first else {
        let names = tier.map(\.name).joined(separator: ", ")
        say("gtg-listen: \(wanted) matches more than one input (\(names)). Try: gtg mic")
        exit(1)
      }
      // AudioUnitSetProperty on the AUHAL, not AUAudioUnit.setDeviceID.
      //
      // setDeviceID returns success and has NO EFFECT here: reading
      // engine.inputNode realizes the node against the current default device,
      // and the Swift wrapper will not move an initialized unit. The symptom
      // is silent and total -- the tap reported the old device's 4-channel
      // format and recorded its empty first channel, so a named device was
      // accepted and then ignored. The C property is the one the graph reads.
      guard let au = input.audioUnit else {
        say("gtg-listen: no input audio unit")
        exit(1)
      }
      var dev = hit.id
      // Uninitialize, set, initialize. All three.
      //
      // An initialized AUHAL accepts the property and keeps the old device,
      // reporting noErr both times. That is not a theory: with the set alone,
      // a named BRIO still delivered the Scarlett's four channels, so the
      // recognizer transcribed the podcast playing through the interface's
      // loopback instead of the person in the room. A device switch that
      // reports success and silently records something else is the worst
      // failure this file can have, so it is verified below rather than
      // trusted.
      AudioUnitUninitialize(au)
      let set = AudioUnitSetProperty(
        au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
      let ready = AudioUnitInitialize(au)
      guard set == noErr, ready == noErr else {
        say("gtg-listen: cannot use \(hit.name) (set \(set), init \(ready))")
        exit(1)
      }

      // Ask the unit what device it ACTUALLY holds now.
      var got = AudioDeviceID(0)
      var gotSize = UInt32(MemoryLayout<AudioDeviceID>.size)
      AudioUnitGetProperty(
        au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &got, &gotSize)
      guard got == hit.id else {
        say("gtg-listen: \(hit.name) was refused; the input is still \(deviceName(got))")
        exit(1)
      }
      if debug { say("input device: \(hit.name) (\(hit.id))") }
    }

    let heard = Heard()
    let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
    let converters = Converters(to: fmt)

    // format: nil, and the converter built from the FIRST BUFFER's own format.
    //
    // Reading outputFormat(forBus:) up front and handing it to installTap is
    // the obvious way and it silently records nothing after a device switch:
    // the node still reports the old device's format, so the tap is installed
    // for four channels on a device that delivers one, and no buffer ever
    // arrives. Asking the buffer what it is cannot disagree with the buffer.
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
      heard.note(level(buf))
      guard let out = converters.convert(buf) else { return }
      if debug, converters.count % 40 == 1 {
        say("in \(buf.format) -> out \(out.format) frames \(out.frameLength) n \(converters.count)")
      }
      feed.yield(AnalyzerInput(buffer: out))
    }
    if debug { say("target format: \(fmt)") }

    // APPEND, never replace.
    //
    // results is an ordered sequence of PHRASES, not one growing transcript.
    // A sentence with a pause in it arrives as two, and keeping only the
    // latest threw the first one away -- so "ten ring dips and a thirty second
    // back stretch" could log the back stretch alone and look like a success.
    // Caught in review; the debug output had been showing five separate
    // result lines all along, and only the last was being kept.
    let text = TextBox()
    let collector = Task {
      do {
        for try await r in transcriber.results {
          let phrase = String(r.text.characters)
          if debug { say("result(final=\(r.isFinal)): \(phrase)") }
          // Volatile results are running guesses at a phrase still being
          // spoken, and each supersedes the last. Appending those would
          // stutter the transcript, so only a finished phrase is kept.
          // reportingOptions is empty, so none should arrive; this does not
          // depend on that staying true.
          if r.isFinal { await text.append(phrase) }
        }
      } catch {
        if debug { say("results failed: \(error)") }
      }
    }

    if debug { say(String(format: "+%.0fms tap installed", Date().timeIntervalSince(t0) * 1000)) }
    do { try await analyzer.start(inputSequence: stream) } catch {
      say("gtg-listen: cannot start the recognizer: \(error.localizedDescription)")
      exit(1)
    }
    if debug { say(String(format: "+%.0fms analyzer.start", Date().timeIntervalSince(t0) * 1000)) }
    engine.prepare()
    do { try engine.start() } catch {
      say("gtg-listen: cannot open the microphone: \(error.localizedDescription)")
      exit(1)
    }

    let stopped = Stopped()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let onInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let onTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    onInt.setEventHandler { stopped.set() }
    onTerm.setEventHandler { stopped.set() }
    onInt.resume()
    onTerm.resume()

    if debug { say(String(format: "+%.0fms READY", Date().timeIntervalSince(t0) * 1000)) }
    // THE READINESS MARKER. The caller must not tell anyone to speak before
    // this line appears: everything before it is setup, and the microphone is
    // shut. hammerspoon/gtg.lua waits for it, so do not reword it without
    // changing that too.
    say("listening...")

    // Three ways to stop, and none of them is you remembering to:
    //   a pause after you have spoken, a short wait if you never do, and a
    //   ceiling so this can never be left running.
    let QUIET_AFTER = 1.5   // a pause this long ends a sentence
    let GIVE_UP_AT = 6.0    // said nothing at all by now, so nothing is coming
    let began = Date()
    while true {
      try? await Task.sleep(nanoseconds: 100_000_000)
      let now = Date().timeIntervalSince(began)
      let s = heard.state
      if stopped.isSet { break }
      if now >= maxSecs { break }
      if s.started, s.quietFor >= QUIET_AFTER { break }
      if !s.started, now >= GIVE_UP_AT { break }
    }

    engine.stop()
    input.removeTap(onBus: 0)
    feed.finish()
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = await collector.value

    let said = await text.get().trimmingCharacters(in: .whitespacesAndNewlines)
    let peak = heard.state.peak
    if said.isEmpty {
      // A dead input device and a person who said nothing look identical on
      // stdout, and only one of them is worth fixing. The peak level tells
      // them apart, so say which one it was.
      if peak < DEAD_DB {
        say(String(format: "heard nothing (peak %.0f dB). Wrong input device? Try: gtg mic", peak))
      } else {
        say("heard nothing I could read as words")
      }
      exit(1)
    }
    print(said)
    exit(0)
  }
}

// The transcript, reachable from the collector task and the main one. One
// phrase at a time, in the order they were spoken.
actor TextBox {
  private var parts: [String] = []
  func append(_ s: String) {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { parts.append(t) }
  }
  func get() -> String { parts.joined(separator: " ") }
}

// One converter per incoming format, built on demand from the buffers that
// actually arrive. A device can change its format under a running tap, so this
// keeps one per shape rather than assuming the first is the only one.
final class Converters: @unchecked Sendable {
  private let lock = NSLock()
  private let target: AVAudioFormat
  private var made: [String: AVAudioConverter] = [:]

  private var seen = 0

  init(to target: AVAudioFormat) { self.target = target }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }

  func convert(_ raw: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let buf = mono(raw) ?? raw
    let from = buf.format
    let tag = "\(from.sampleRate)/\(from.channelCount)/\(from.commonFormat.rawValue)"
    lock.lock()
    seen += 1
    var conv = made[tag]
    if conv == nil {
      conv = AVAudioConverter(from: from, to: target)
      made[tag] = conv
    }
    lock.unlock()
    guard let conv else { return nil }

    let ratio = target.sampleRate / from.sampleRate
    let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
    var err: NSError?
    var gave = false
    conv.convert(to: out, error: &err) { _, status in
      if gave {
        status.pointee = .noDataNow
        return nil
      }
      gave = true
      status.pointee = .haveData
      return buf
    }
    guard err == nil, out.frameLength > 0 else { return nil }
    return out
  }
}

// Fold every channel into one, by averaging.
//
// AVAudioConverter does NOT downmix: handed four channels it takes the first
// and discards the rest. On a 2i2 the first channel is the instrument input
// nobody is plugged into, so the recognizer was fed several seconds of
// digital silence while the room was speaking into channel three. Averaging
// first means the converter only ever sees one channel and has nothing to
// throw away.
private func mono(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
  let chans = Int(buf.format.channelCount)
  guard chans > 1, let src = buf.floatChannelData else { return nil }
  guard
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate,
      channels: 1, interleaved: false),
    let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength),
    let dst = out.floatChannelData
  else { return nil }
  let n = Int(buf.frameLength)
  let scale = 1 / Float(chans)
  for i in 0..<n {
    var sum: Float = 0
    for c in 0..<chans { sum += src[c][i] }
    dst[0][i] = sum * scale
  }
  out.frameLength = buf.frameLength
  return out
}
