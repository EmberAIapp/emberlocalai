import Foundation
import AVFoundation
import Speech

/// Mains-libres voice for Mode Her (§4.E). Local STT (SFSpeechRecognizer, on-device) + a natural
/// local voice (Kokoro WAV played back; AVSpeech only as last resort). No cloud.
///
/// TWO engines, chosen automatically at session start:
///  • FULL-DUPLEX (preferred): one continuous AVAudioEngine with the Mac's voice-processing unit
///    (`setVoiceProcessingEnabled`) → echo cancellation. Ember's voice is played through an
///    AVAudioPlayerNode on the SAME engine, so the (echo-cancelled) mic only hears the USER —
///    which lets the user talk OVER Ember (barge-in), like ChatGPT voice mode.
///  • TURN-BASED (fallback if voice processing is unavailable): the validated per-turn mic that
///    opens, auto-sends on a pause, and is reopened by the view after Ember finishes speaking.
///
/// All Apple callbacks fire on background/realtime threads; to avoid the @MainActor isolation
/// trap AND Swift-6 "sending self", those closures capture ONLY Sendable values (a RequestBox,
/// an AsyncStream continuation) — never `self` — and a MainActor task applies the updates.
private struct STTUpdate: Sendable { var text: String?; var isFinal: Bool; var failed: Bool }

/// Sendable holder so the realtime audio tap can append to the *current* recognition request
/// without touching the main actor (the request swaps per turn).
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = req; lock.unlock(); r?.append(b) }
}

@MainActor
final class SpeechController: ObservableObject {
    @Published var listening = false        // a user turn is open (mic capturing the user)
    @Published var speaking = false          // Ember is playing a reply
    @Published var authorized = false
    @Published var partial = ""
    @Published var fullDuplex = false        // AEC engaged → user can talk over Ember

    /// Called (main actor) with the user's transcript at the end of each turn.
    var onTranscript: ((String) -> Void)?
    /// A pause longer than this (no new words) ends the user's turn → auto-send.
    var silenceSeconds: Double = 1.2

    private let synth = AVSpeechSynthesizer()

    // --- Full-duplex (continuous engine) ---
    private var fdEngine: AVAudioEngine?
    private var fdPlayer: AVAudioPlayerNode?
    private let box = RequestBox()
    private enum Mode { case idle, listening, speaking }
    private var mode: Mode = .idle
    private var fdReq: SFSpeechAudioBufferRecognitionRequest?
    private var fdTask: SFSpeechRecognitionTask?
    private var fdConsumer: Task<Void, Never>?
    private var fdSilence: Task<Void, Never>?
    private var fdEndTimer: Task<Void, Never>?
    private var fdHeard = false
    private var recognizer: SFSpeechRecognizer?
    private let kokoroFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!

    // --- Turn-based fallback ---
    private var tbEngine: AVAudioEngine?
    private var tbReq: SFSpeechAudioBufferRecognitionRequest?
    private var tbTask: SFSpeechRecognitionTask?
    private var tbConsumer: Task<Void, Never>?
    private var tbSilence: Task<Void, Never>?
    private var tbFallback: Task<Void, Never>?
    private var tbHeard = false
    private var simplePlayer: AVAudioPlayer?
    private var speakingOff: Task<Void, Never>?
    private var localeId = "fr-FR"
    private var spokenText = ""          // what Ember is currently saying (reject false barge-ins)

    /// True if a recognized partial is mostly Ember's own current speech (imperfect AEC residual),
    /// so we DON'T treat it as the user barging in.
    private func echoLike(_ t: String) -> Bool {
        let s = spokenText.lowercased()
        guard s.count > 8 else { return false }
        func w(_ x: String) -> Set<String> { Set(x.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 }) }
        let tw = w(t); if tw.isEmpty { return true }
        let sw = w(s)
        return Double(tw.filter { sw.contains($0) }.count) / Double(tw.count) >= 0.4
    }

    // MARK: - Authorisation
    func requestAuth() { Task { self.authorized = (await Self.authStatus() == .authorized) } }
    nonisolated private static func authStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
    }

    // MARK: - Public session API (the view calls these)

    /// Start a hands-free voice session. Prefers full-duplex (barge-in); falls back to turn-based.
    /// Set true to try full-duplex (barge-in). OFF by default: it's unstable past ~2 turns and the
    /// validated turn-based loop is the reliable path (fiabilité d'abord). Re-enable once stabilised.
    var allowFullDuplex = false

    func startVoice(locale: String) {
        localeId = locale
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { return }
        recognizer = rec
        if allowFullDuplex && startFullDuplex() { fullDuplex = true; beginFDTurn(.listening) }
        else { fullDuplex = false; startTurnBased() }
    }

    func endVoice() {
        if fdEngine != nil { endFullDuplex() } else { stopListening() }
        stopSpeaking()
    }

    /// True while a session (either kind) is live.
    var sessionActive: Bool { fdEngine != nil || tbEngine != nil }

    // MARK: - Full-duplex engine

    private func startFullDuplex() -> Bool {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        // Echo cancellation. If unavailable, bail → caller uses the turn-based path.
        do { try input.setVoiceProcessingEnabled(true) } catch { return false }
        let player = AVAudioPlayerNode()
        eng.attach(player)
        eng.connect(player, to: eng.mainMixerNode, format: kokoroFormat)
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return false }
        let b = box
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in b.append(buf) }  // captures only `box`
        eng.prepare()
        do { try eng.start() } catch { eng.inputNode.removeTap(onBus: 0); return false }
        fdEngine = eng; fdPlayer = player
        return true
    }

    private func endFullDuplex() {
        endFDRecognition()
        fdEndTimer?.cancel(); fdEndTimer = nil
        fdPlayer?.stop()
        if let eng = fdEngine { eng.inputNode.removeTap(onBus: 0); eng.stop() }
        fdEngine = nil; fdPlayer = nil; box.set(nil)
        mode = .idle; listening = false; speaking = false; partial = ""; fullDuplex = false
    }

    private func beginFDTurn(_ m: Mode) {
        endFDRecognition()
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // §7 : JAMAIS de serveur Apple — on tient la promesse Info.plist
        fdReq = req; box.set(req)
        partial = ""; fdHeard = false
        mode = m; listening = (m == .listening)
        let (stream, cont) = AsyncStream.makeStream(of: STTUpdate.self)
        fdTask = Self.makeTask(rec: rec, req: req, cont: cont)
        fdConsumer = Task { @MainActor in for await u in stream { self.handleFD(u) } }
    }

    private func handleFD(_ u: STTUpdate) {
        if let t = u.text, !t.isEmpty {
            if mode == .speaking {
                // Only a REAL interruption cuts Ember off: a long-enough partial that isn't just
                // her own residual voice (imperfect AEC). This is what makes full-duplex stable.
                if t.count >= 6 && !echoLike(t) { bargeIn(with: t) }
                return
            }
            partial = t; fdHeard = true; scheduleFDSilence()
        }
        if u.isFinal { finishFDTurn(text: u.text) }
        else if u.failed && mode == .listening { beginFDTurn(.listening) }
    }

    private func bargeIn(with t: String) {
        fdEndTimer?.cancel()
        fdPlayer?.stop()
        speaking = false
        mode = .listening; listening = true
        partial = t; fdHeard = true
        scheduleFDSilence()                                // same request keeps capturing the user
    }

    private func scheduleFDSilence() {
        fdSilence?.cancel()
        fdSilence = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(silenceSeconds * 1_000_000_000))
            guard !Task.isCancelled, self.mode == .listening, self.fdHeard else { return }
            self.fdReq?.endAudio()                          // → final → finishFDTurn
        }
    }

    private func finishFDTurn(text: String?) {
        fdSilence?.cancel()
        let out = (text?.isEmpty == false ? text! : partial).trimmingCharacters(in: .whitespacesAndNewlines)
        listening = false; mode = .idle
        endFDRecognition(); box.set(nil)
        if !out.isEmpty { onTranscript?(out) }              // app replies → playWav(...) → speaking
        else if fdEngine != nil { beginFDTurn(.listening) } // heard nothing → keep listening
    }

    private func playFDWav(_ data: Data) {
        guard let eng = fdEngine, let p = fdPlayer, eng.isRunning,
              let buf = Self.pcmBuffer(from: data, format: kokoroFormat) else { return }
        fdEndTimer?.cancel(); p.stop()
        beginFDTurn(.speaking)                              // barge-in watch while she speaks
        speaking = true
        p.scheduleBuffer(buf, at: nil, options: []) { }
        if !p.isPlaying { p.play() }
        let dur = Double(buf.frameLength) / buf.format.sampleRate
        fdEndTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((dur + 0.2) * 1_000_000_000))
            if self.speaking { self.fdPlaybackEnded() }
        }
    }

    private func fdPlaybackEnded() {
        fdPlayer?.stop(); speaking = false
        if fdEngine != nil { beginFDTurn(.listening) }      // her turn ended → next user turn
    }

    private func endFDRecognition() {
        fdSilence?.cancel(); fdSilence = nil
        fdTask?.cancel(); fdTask = nil
        fdConsumer?.cancel(); fdConsumer = nil
        fdReq = nil
    }

    nonisolated private static func makeTask(rec: SFSpeechRecognizer, req: SFSpeechAudioBufferRecognitionRequest,
                                             cont: AsyncStream<STTUpdate>.Continuation) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            cont.yield(STTUpdate(text: result?.bestTranscription.formattedString,
                                 isFinal: result?.isFinal ?? false, failed: error != nil))
            if (result?.isFinal ?? false) || error != nil { cont.finish() }
        }
    }

    nonisolated private static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ember_tts_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let fmt = file.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: buf)
            return buf
        } catch { return nil }
    }

    // MARK: - TTS (routes to the active engine; AVSpeech only as last resort)

    func playWav(_ data: Data, text: String = "") {
        spokenText = text
        if fdEngine != nil { playFDWav(data); return }
        // turn-based playback (separate AVAudioPlayer)
        stopSimplePlayback()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        simplePlayer = p; speaking = true; p.play()
        let dur = p.duration
        speakingOff = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, dur) * 1_000_000_000) + 150_000_000)
            if self.simplePlayer === p { self.speaking = false; self.simplePlayer = nil }
        }
    }

    func speakFallback(_ text: String, locale: String = "fr-FR") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        speaking = true
        synth.speak(u)
        speakingOff = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Double(t.count) * 0.06 * 1_000_000_000) + 1_000_000_000)
            if !self.synth.isSpeaking { self.speaking = false; if self.fdEngine != nil { self.beginFDTurn(.listening) } }
        }
    }

    func stopSpeaking() {
        speakingOff?.cancel(); speakingOff = nil
        fdEndTimer?.cancel(); fdEndTimer = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        fdPlayer?.stop()
        stopSimplePlayback()
        speaking = false
    }

    private func stopSimplePlayback() { simplePlayer?.stop(); simplePlayer = nil }

    /// Map a 2-letter system language to a BCP-47 locale for the fallback synthesizer / recognizer.
    static func locale(for lang: String) -> String {
        switch lang.prefix(2).lowercased() {
        case "fr": return "fr-FR"; case "es": return "es-ES"; case "de": return "de-DE"
        case "pt": return "pt-BR"; case "it": return "it-IT"; default: return "en-US"
        }
    }

    // MARK: - Turn-based STT (validated fallback). Mic opens per turn; a pause auto-sends.

    func toggleListening(locale: String = "fr-FR") {
        if listening { finalizeTB() } else { startTurnBased(locale: locale) }
    }

    private func startTurnBased(locale: String? = nil) {
        let loc = locale ?? localeId
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: loc)), rec.isAvailable else { return }
        let eng = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // §7 : JAMAIS de serveur Apple — on tient la promesse Info.plist
        tbReq = req; partial = ""; tbHeard = false
        let (stream, cont) = AsyncStream.makeStream(of: STTUpdate.self)
        do { tbTask = try Self.beginTB(rec: rec, engine: eng, req: req, cont: cont) }
        catch { cleanupTB(); return }
        tbEngine = eng; listening = true
        tbConsumer = Task { @MainActor in
            for await u in stream {
                if let t = u.text, !t.isEmpty { self.partial = t; self.tbHeard = true; self.scheduleTBSilence() }
                if u.isFinal { self.finishTB(send: u.text, fallbackToPartial: false) }
                else if u.failed { self.finishTB(send: nil, fallbackToPartial: true) }
            }
        }
    }

    private func scheduleTBSilence() {
        tbSilence?.cancel()
        tbSilence = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(silenceSeconds * 1_000_000_000))
            guard !Task.isCancelled, self.listening, self.tbHeard else { return }
            self.finalizeTB()
        }
    }

    private func finalizeTB() {
        guard listening else { return }
        tbSilence?.cancel(); tbReq?.endAudio()
        tbFallback?.cancel()
        tbFallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, self.listening else { return }
            self.finishTB(send: self.partial, fallbackToPartial: false)
        }
    }

    private func finishTB(send text: String?, fallbackToPartial: Bool) {
        let out = (text?.isEmpty == false ? text : nil) ?? (fallbackToPartial ? partial : nil)
        cleanupTB()
        if let out, !out.isEmpty { onTranscript?(out) }
    }

    func stopListening() {
        tbSilence?.cancel(); tbFallback?.cancel()
        tbReq?.endAudio()
        cleanupTB()
    }

    private func cleanupTB() {
        tbSilence?.cancel(); tbSilence = nil
        tbFallback?.cancel(); tbFallback = nil
        if let eng = tbEngine { if eng.isRunning { eng.stop() }; eng.inputNode.removeTap(onBus: 0) }
        tbEngine = nil
        tbTask?.cancel(); tbTask = nil
        tbConsumer?.cancel(); tbConsumer = nil
        tbReq = nil; tbHeard = false; listening = false
    }

    nonisolated private static func beginTB(
        rec: SFSpeechRecognizer, engine: AVAudioEngine,
        req: SFSpeechAudioBufferRecognitionRequest, cont: AsyncStream<STTUpdate>.Continuation
    ) throws -> SFSpeechRecognitionTask {
        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        try engine.start()
        return rec.recognitionTask(with: req) { result, error in
            cont.yield(STTUpdate(text: result?.bestTranscription.formattedString,
                                 isFinal: result?.isFinal ?? false, failed: error != nil))
            if (result?.isFinal ?? false) || error != nil { cont.finish() }
        }
    }
}
