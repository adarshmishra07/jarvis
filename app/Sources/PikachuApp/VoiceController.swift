import AppKit
import AVFoundation
import Combine
import Carbon.HIToolbox
import PikachuCore

/// Wires the mic to local speech-to-text, the ask flow and spoken replies.
/// TALK is hands-free: it listens, answers when you pause, and stops talking when you start. Option+Space is hold-to-talk.
@MainActor
final class VoiceController {
    private let model: AppModel
    private let voice = KokoroVoice()
    private lazy var speaker = Speaker(voice: voice)
    private let transcriber = QwenTranscriber()
    /// Tells a finished sentence from a pause to think. Without the model file, a fixed pause ends what you say.
    private let turn = Bundle.main.resourceURL.flatMap { try? SmartTurn(modelPath: $0.appendingPathComponent("models/smart-turn.onnx").path) }
    private var vocabularyWatch: AnyCancellable?
    private var ptt: PushToTalk?
    private var hotkey: Hotkey?
    private var noteHotkey: Hotkey?
    /// True while the mic is recording a note to save rather than a question.
    private var noting = false
    private let mic = MicRecorder()
    private var vad = VoiceActivity()
    /// Hands-free conversation is on.
    private var live = false
    /// When your last sentence ended, and whether the one now starting came soon enough after it to be its second half.
    private var lastSpeechEnd: Date?
    private var continuing = false
    private static let continueWithin: TimeInterval = 2.5
    /// A question that stops mid-sentence, held while Jarvis waits for the rest.
    private var held: String?
    private var speechStarts = 0
    private static let unfinishedWait: Duration = .milliseconds(2500)
    /// Standby: the mic listens for "Hey Jarvis" while nothing else uses it.
    private var standby = false
    private var wakeWatch: AnyCancellable?
    /// "Hey Jarvis" listens only while the Mac is unlocked and awake, so nobody can talk to it while you are away.
    /// Away until the Mac says otherwise: the screen is locked, the Mac is asleep, or another user is on it.
    private var screenLocked = true
    private var asleep = false
    private var switchedOut = false
    private var locked: Bool { screenLocked || asleep || switchedOut }
    private var lockWatch: [NSObjectProtocol] = []

    /// The real lock state, read from the login session (no permission needed).
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool ?? false
        return (session["CGSSessionScreenIsLocked"] as? Bool ?? false) || !onConsole
    }

    /// How long after Jarvis stops speaking its own voice may still reach the mic (room echo, the last chunk).
    private var lastSpoke = Date.distantPast
    private static let echoGrace: TimeInterval = 1.5
    /// Only short bursts of speech are checked for the wake word; longer talk is not transcribed at all.
    private static let wakeSeconds = 8.0

    /// The floating pill, refreshed a few times a second from the state below.
    private var pill: FloatingStatus?
    private var pillLoop: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        if UserDefaults.standard.string(forKey: "snapshot") == nil {
            pill = FloatingStatus { [weak self] in self?.stopFromPill() }
            // ponytail: polls at 5 Hz instead of observing each source; cheap, and states change in under a frame anyway.
            // A main-actor loop, not a Timer: MainActor.assumeIsolated in a Timer callback crashed in the Swift runtime (23 Oct 2026).
            pillLoop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.refreshPill()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        model.onSentence = { [weak self, weak model] text, turn in self?.heardSentence(); self?.speaker.enqueue(text) { model?.reveal(turn, text) } }
        let ptt = PushToTalk(recorder: mic, transcriber: transcriber) { [weak model, weak self] text in
            guard let model, let self else { return }
            if await self.noting { await model.remember(SpeechScript.fixSpelling(text, model.spellings)); return }
            // Not awaited: push-to-talk is free again at once, so you can press to interrupt while Jarvis answers.
            Task { @MainActor in
                while model.asking { try? await Task.sleep(for: .milliseconds(50)) }
                model.question = SpeechScript.fixSpelling(text, model.spellings)
                self.ackIfSlow()
                await model.ask(speak: true)
            }
        }
        ptt.onState = { [weak model, weak self] state in
            let note = self?.noting ?? false
            model?.voiceStatus = switch state { case .recording: note ? "Recording note" : "Listening"; case .transcribing: "Transcribing"; case .idle: nil }
            if state == .idle { Task { @MainActor in self?.resumeStandby() } }
        }
        model.onMicTap = { [weak self] note in self?.tap(note: note) }
        model.onControl = { [weak self] action in self?.control(action) }
        model.onTrainWake = { [weak self] in self?.trainWake() }
        model.prepareFile = { [transcriber] url in await FilePrep.prepare(url, transcriber: transcriber) }
        model.onPreviewVoice = { [weak self] in self?.speaker.cancel(); self?.speaker.enqueue("Hello, I'm Jarvis. Ready when you are.") }
        self.ptt = ptt
        // The wake word is always in the speech model's list of expected words, so it writes "Jarvis", not "Travis".
        vocabularyWatch = model.$vocabulary.sink { [transcriber] words in Task { await transcriber.setVocabulary(["Hey Jarvis"] + words) } }
        hotkey = Hotkey(id: 1, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey),
                        pressed: { [weak self] in Task { @MainActor in self?.start(note: false) } },
                        released: { [weak self] in Task { @MainActor in await self?.ptt?.release() } })
        // Option+Shift+Space: hold to speak a note into memory from any app.
        noteHotkey = Hotkey(id: 2, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey),
                            pressed: { [weak self] in Task { @MainActor in self?.start(note: true) } },
                            released: { [weak self] in Task { @MainActor in await self?.ptt?.release() } })
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted, UserDefaults.standard.string(forKey: "snapshot") == nil else { return }
            Task { @MainActor in
                self?.watchLock()
                self?.wakeWatch = self?.model.$wakeWord.sink { [weak self] on in Task { @MainActor in on ? self?.resumeStandby() : self?.pauseStandby() } }
            }
        }
        Task.detached(priority: .utility) { [transcriber, voice] in
            _ = try? await transcriber.load()
            await voice.warmUp()
        }
    }

    private func start(note: Bool) {
        guard !live else { return } // hands-free already listens
        // While Jarvis waits on you, a question would end its task: only a spoken note is allowed then.
        if model.waitingForYou && !note { model.notice = "Type your reply to Jarvis."; return }
        if !model.waitingForYou { speaker.cancel(); model.interrupt() } // pressing to talk stops the current answer
        guard ptt?.state == .idle else { return }
        pauseStandby()
        noting = note
        ptt?.press()
    }

    /// TALK starts or ends a hands-free conversation; NOTE starts or stops a note-taking session.
    private func tap(note: Bool) {
        note ? toggleNoteTaking() : toggleLive()
    }

    /// Note taking: writes down everything said until stopped, from the mic ("Me") and the Mac's sound ("Them", such as a
    /// call), then Jarvis writes the meeting notes. No wake commands count while it runs: everything is just written down.
    /// The last line being transcribed: each waits for the one before, so lines stay in the order they were said, and
    /// stopping waits for the last one.
    private var lastNote: Task<Void, Never>?
    private var systemVAD = VoiceActivity()
    private var echo = EchoFilter()
    private var systemAudio: AnyObject?

    private func toggleNoteTaking() {
        if model.noteSession != nil {
            _ = mic.stop(); stopSystemAudio(); model.voiceStatus = "Saving notes"
            // Whatever was being said when you stopped, from either side.
            if let rest = vad.finish(), PushToTalk.usable(rest) { lastNote = noteLine(rest, side: .me) }
            if let rest = systemVAD.finish(), PushToTalk.usable(rest) { lastNote = noteLine(rest, side: .them) }
            let last = lastNote
            Task {
                await last?.value
                await model.stopNoteTaking(); model.voiceStatus = nil; resumeStandby()
            }
            return
        }
        guard !live, ptt?.state == .idle else { return }
        pauseStandby()
        vad = VoiceActivity(); systemVAD = VoiceActivity(); echo = EchoFilter()
        do { try mic.start { [weak self] chunk in Task { @MainActor in self?.hearNotes(chunk) } } } catch { model.notice = "Could not start the mic."; return }
        startSystemAudio()
        model.startNoteTaking(); model.voiceStatus = "Taking notes"
    }

    /// The other side of a call. If macOS has not allowed system audio recording, notes still work from the mic alone.
    private func startSystemAudio() {
        guard #available(macOS 14.2, *) else { return }
        let capture = SystemAudio()
        do {
            try capture.start { [weak self] chunk in Task { @MainActor in self?.hearCall(chunk) } }
            systemAudio = capture
        } catch {
            model.notice = "Taking notes from your mic only. To include the other side of calls, allow Jarvis under System Settings > Privacy & Security > Screen & System Audio Recording."
        }
    }

    private func stopSystemAudio() {
        if #available(macOS 14.2, *) { (systemAudio as? SystemAudio)?.stop() }
        systemAudio = nil
    }

    private func hearCall(_ chunk: [Float]) {
        guard model.noteSession != nil else { return }
        echo.system(chunk, endingAt: Date())
        for case let .ended(samples) in systemVAD.feed(chunk) where PushToTalk.usable(samples) { lastNote = noteLine(samples, side: .them) }
    }

    private func hearNotes(_ chunk: [Float]) {
        guard model.noteSession != nil else { return }
        if speaker.pending > 0 { lastSpoke = Date() }
        let selfHeard = Date().timeIntervalSince(lastSpoke) < Self.echoGrace
        for case let .ended(samples) in vad.feed(chunk) where PushToTalk.usable(samples) {
            guard !selfHeard else { continue } // Jarvis's own voice is never written into the notes
            // The call coming out of the speakers (no headphones) is already written down as "Them".
            let end = Date(), start = end.addingTimeInterval(-Double(samples.count) / PushToTalk.sampleRate)
            if echo.isEcho(from: start, to: end) { continue }
            lastNote = noteLine(samples, side: .me)
        }
    }

    private func noteLine(_ samples: [Float], side: Side) -> Task<Void, Never> {
        let previous = lastNote
        return Task {
            let text = try? await transcriber.transcribe(samples, sampleRate: PushToTalk.sampleRate)
            await previous?.value
            guard let text, let line = PushToTalk.cleaned(text) else { return }
            await model.addNoteLine(SpeechScript.fixSpelling(line, model.spellings), speaker: side)
        }
    }

    /// Jarvis switched note taking on or off: done once its reply has been said, so the reply is not in the notes.
    private func control(_ action: String) {
        Task {
            while model.asking || speaker.pending > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard (action == "startNotes") != (model.noteSession != nil), model.voiceStatus != "Saving notes" else { return }
            if live { toggleLive() }
            toggleNoteTaking()
        }
    }

    /// A reminder said out loud, only while you are at the Mac and not on a call.
    func announce(_ text: String) {
        guard !locked, !onCall else { return }
        speaker.enqueue("Reminder: \(text)")
    }

    private func toggleLive() {
        if live {
            live = false; exchange = false; model.live = false; model.voiceStatus = nil
            speaker.cancel(); model.interrupt() // STOP TALKING stops the voice now, not after the sentence
            _ = mic.stop()
            resumeStandby()
            return
        }
        guard ptt?.state == .idle, model.noteSession == nil else { return }
        pauseStandby()
        speaker.cancel() // switching on echo cancellation restarts the audio engine; nothing may be mid-playback
        vad = listening()
        do { try mic.start(echoCancel: true) { [weak self] chunk in Task { @MainActor in self?.hear(chunk) } } } catch { model.notice = "Could not start the mic."; return }
        live = true; model.live = true; model.voiceStatus = "Listening"
    }

    private func hear(_ chunk: [Float]) {
        guard live else { return }
        vad.raised = speaker.pending > 0
        for event in vad.feed(chunk) {
            switch event {
            case .started:
                continuing = lastSpeechEnd.map { Date().timeIntervalSince($0) < Self.continueWithin } ?? false
                speechStarts += 1
                // Talking over Jarvis's voice stops it at once. While it is only thinking, a sound is not enough: the
                // answer is dropped once real words are heard (below), so a cough or a door cannot kill it.
                if !model.waitingForYou, speaker.pending > 0 { speaker.cancel(); model.interrupt() }
                model.voiceStatus = "Hearing you"
            case let .ended(samples):
                lastSpeechEnd = Date()
                let continuing = self.continuing
                Task { await self.answer(samples, continuing: continuing) }
            }
        }
    }

    /// Listening for you to talk to Jarvis: Smart Turn decides when you have finished, after a short pause.
    /// ponytail: the check runs on the main actor, 10 to 140 ms once per pause (slowest while models load); move it off if the UI stutters.
    private func listening() -> VoiceActivity {
        var vad = VoiceActivity()
        guard let turn else { return vad }
        vad.endCheck = { speech in
            let start = Date()
            let p = (try? turn.probability(speech)) ?? 0 // unsure: wait for the longer pause rather than cut you off
            voiceLog.notice("turn check \(String(format: "%.2f", p), privacy: .public) in \(Int(Date().timeIntervalSince(start) * 1000), privacy: .public) ms")
            return p > 0.5
        }
        return vad
    }

    private func answer(_ samples: [Float], continuing: Bool) async {
        guard PushToTalk.usable(samples) else { model.voiceStatus = live ? "Listening" : nil; return }
        model.voiceStatus = "Transcribing"
        let heardAt = Date()
        let text = try? await transcriber.transcribe(samples, sampleRate: PushToTalk.sampleRate)
        voiceLog.notice("transcribed in \(Int(Date().timeIntervalSince(heardAt) * 1000), privacy: .public) ms")
        model.voiceStatus = live ? "Listening" : nil
        guard live, let text, let said = PushToTalk.cleaned(text) else { return }
        if model.waitingForYou { if PushToTalk.isStopPhrase(said) { speaker.cancel() }; model.notice = "Type your reply to Jarvis."; return }
        speaker.cancel(); model.interrupt() // words were heard: the answer in progress gives way
        while model.asking { try? await Task.sleep(for: .milliseconds(50)) } // the interrupted answer winds down
        // "Stop" ends the conversation: Jarvis goes quiet until you press TALK or say "Hey Jarvis" again.
        if PushToTalk.isStopPhrase(said) { model.settleInterrupted(); toggleLive(); return }
        var heard = said
        switch WakeWord.parse(heard, learned: model.wakeLearned) {
        case .sleep?: model.settleInterrupted(); toggleLive(); return
        case .startNotes?: model.settleInterrupted(); toggleLive(); toggleNoteTaking(); return
        case .stopNotes?, .listen?: model.settleInterrupted(); return
        case let .ask(rest)?: heard = rest
        case nil: break
        }
        // A pause split one sentence in two and Jarvis had not said a word yet: send it again as one question.
        // Otherwise the interrupted answer stays stopped and this is a new question.
        let earlier = continuing ? model.retractUnanswered() : nil
        if earlier == nil { model.settleInterrupted() }
        let start = [held, earlier].compactMap { $0 }.joined(separator: " ")
        held = nil
        let question = start.isEmpty ? heard : "\(start) \(heard)"
        // "Then there is a call at..." was a pause to think: wait a moment for the rest before asking.
        if PushToTalk.soundsUnfinished(question) {
            held = question
            let mark = speechStarts
            try? await Task.sleep(for: Self.unfinishedWait)
            guard live, speechStarts == mark, held == question else { return } // you went on: the next part carries this one
            held = nil
        }
        model.question = SpeechScript.fixSpelling(question, model.spellings)
        ackIfSlow()
        await model.ask(speak: true)
    }

    /// Sentences of answers spoken so far, and when the current spoken question was sent.
    private var sentences = 0
    private var askedAt: Date?
    private static let ackAfter: Duration = .milliseconds(800)
    private static let acks = ["One sec.", "Let me check.", "Give me a moment.", "On it."]

    /// A slow answer gets a short "one sec" first, the way a person would, so you know you were heard.
    private func ackIfSlow() {
        let before = sentences
        askedAt = Date()
        Task {
            try? await Task.sleep(for: Self.ackAfter)
            guard model.asking, sentences == before, speaker.pending == 0 else { return }
            speaker.enqueue(Self.acks.randomElement()!)
        }
    }

    private func heardSentence() {
        sentences += 1
        if let askedAt { voiceLog.notice("first sentence after \(String(format: "%.1f", Date().timeIntervalSince(askedAt)), privacy: .public) s") }
        askedAt = nil
    }

    // MARK: Training "Hey Jarvis"

    private static let trainingTries = 5
    private static let maxLearned = 20

    /// You say "Hey Jarvis" a few times the way you normally do; how speech-to-text writes it for your voice is learned,
    /// so it wakes for you even when it mishears the name. Common phrases are never learned.
    private func trainWake() {
        guard model.training == nil, !live, model.noteSession == nil, ptt?.state == .idle else { return }
        pauseStandby()
        speaker.cancel()
        model.training = []
        vad = VoiceActivity()
        do { try mic.start { [weak self] chunk in Task { @MainActor in self?.hearTraining(chunk) } } }
        catch { model.training = nil; model.notice = "Could not start the mic."; resumeStandby(); return }
        // Never left listening: training ends after a minute even if fewer tries were heard.
        Task { try? await Task.sleep(for: .seconds(60)); if model.training != nil { finishTraining() } }
    }

    private func hearTraining(_ chunk: [Float]) {
        guard model.training != nil else { return }
        for case let .ended(samples) in vad.feed(chunk) where PushToTalk.usable(samples) && Double(samples.count) / PushToTalk.sampleRate <= Self.wakeSeconds {
            Task {
                let text = (try? await transcriber.transcribe(samples, sampleRate: PushToTalk.sampleRate))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard model.training != nil else { return }
                model.training?.append(text.isEmpty ? "(nothing heard)" : text)
                if (model.training?.count ?? 0) >= Self.trainingTries { finishTraining() }
            }
        }
    }

    private func finishTraining() {
        guard let heard = model.training else { return }
        _ = mic.stop()
        // Tries it already understands need nothing new; the rest are learned if they are specific enough.
        let new = heard.filter { WakeWord.parse($0, learned: model.wakeLearned) != .listen }.compactMap(WakeWord.learnable)
        model.wakeLearned = Array(Set(model.wakeLearned + new)).sorted().suffix(Self.maxLearned)
        let understood = heard.filter { WakeWord.parse($0, learned: model.wakeLearned) == .listen }.count
        model.notice = "Hey Jarvis training done: \(understood) of \(heard.count) tries now wake Jarvis."
        model.training = nil
        resumeStandby()
    }

    // MARK: Floating pill

    private func refreshPill() {
        let state: FloatingStatus.State? =
            speaker.pending > 0 ? .speaking
            : model.asking || model.voiceStatus == "Transcribing" ? .thinking
            : live || ptt?.state == .recording ? .listening
            : model.noteSession != nil ? .notes
            : nil
        pill?.show(state)
        endExchangeIfQuiet()
        ticks += 1
        // Not during hands-free talk: its echo cancellation could itself look like another app on the mic.
        if ticks % 5 == 0, !live { watchCalls() }
    }

    /// While another app uses the mic (a call, a recording), "Hey Jarvis" is off: what is said there is not for Jarvis.
    private var onCall = false
    private var ticks = 0

    private func watchCalls() {
        let call = MicUse.othersUsing()
        guard call != onCall else { return }
        onCall = call
        voiceLog.notice("\(call ? "another app is using the mic: Hey Jarvis paused" : "mic free again", privacy: .public)")
        if call { pauseStandby() } else { resumeStandby() }
    }

    /// Clicking the pill: notes stop and are saved, hands-free talk ends, or the current answer is silenced.
    private func stopFromPill() {
        if model.noteSession != nil { if model.voiceStatus != "Saving notes" { toggleNoteTaking() }; return }
        if live { toggleLive(); return }
        speaker.cancel(); model.interrupt(); model.settleInterrupted()
    }

    // MARK: "Hey Jarvis"

    private func watchLock() {
        screenLocked = Self.screenIsLocked()
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (VoiceController) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    change(self)
                    if self.locked {
                        self.pauseStandby()
                        if self.live { self.toggleLive() } // away from the Mac: hands-free talk ends too
                    } else { self.resumeStandby() }
                }
            }
        }
        lockWatch = [
            on(distributed, .init("com.apple.screenIsLocked")) { $0.screenLocked = true },
            on(distributed, .init("com.apple.screenIsUnlocked")) { $0.screenLocked = false },
            on(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true },
            // Waking is not unlocking: read the lock state again.
            on(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.screenLocked = Self.screenIsLocked() },
            on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.switchedOut = true },
            on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.switchedOut = false; $0.screenLocked = Self.screenIsLocked() },
        ]
    }

    private func resumeStandby() {
        guard model.wakeWord, !locked, !onCall, !standby, !live, model.noteSession == nil, ptt?.state == .idle else { return }
        vad = listening()
        do { try mic.start { [weak self] chunk in Task { @MainActor in self?.hearWake(chunk) } } } catch { return }
        standby = true
        voiceLog.notice("standby: listening for Hey Jarvis")
    }

    private func pauseStandby() {
        guard standby else { return }
        standby = false
        _ = mic.stop()
    }

    /// Speech heard but not readable this many times in a row: the audio path is rebuilt (once this needed a relaunch).
    private static let unreadBeforeRebuild = 3
    private var unreadInRow = 0

    private func hearWake(_ chunk: [Float]) {
        guard standby else { return }
        if speaker.pending > 0 { lastSpoke = Date() }
        // While Jarvis speaks (and just after), the mic can hear Jarvis itself: then only "stop" counts, so nothing it
        // reads out (a page, an email) can ever start a request.
        let selfHeard = Date().timeIntervalSince(lastSpoke) < Self.echoGrace
        for case let .ended(samples) in vad.feed(chunk) where PushToTalk.usable(samples) {
            let seconds = Double(samples.count) / PushToTalk.sampleRate
            voiceLog.notice("standby heard \(String(format: "%.1f", seconds), privacy: .public) s of speech\(selfHeard ? " while Jarvis spoke" : "", privacy: .public)")
            guard seconds <= Self.wakeSeconds else { continue } // long talk is never transcribed
            Task {
                let text = try? await transcriber.transcribe(samples, sampleRate: PushToTalk.sampleRate)
                // Off unless switched on (defaults write dev.agentpikachu.app wakeDebug -bool true): the words of short
                // phrases that did not wake Jarvis, to tune the wake word. Never anything longer.
                let debug = UserDefaults.standard.bool(forKey: "wakeDebug") && seconds <= 2
                guard let text, let heard = PushToTalk.cleaned(text) else {
                    let level = 10 * log10(max(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count), 1e-10))
                    voiceLog.notice("standby: nothing transcribed, level \(Int(level), privacy: .public) dB\(debug ? " [\(text ?? "")]" : "", privacy: .public)")
                    unreadInRow += 1
                    if unreadInRow >= Self.unreadBeforeRebuild, standby, speaker.pending == 0 {
                        unreadInRow = 0
                        pauseStandby(); AudioIO.shared.rebuild(); resumeStandby()
                    }
                    return
                }
                unreadInRow = 0
                // A plain "stop" while Jarvis is answering silences it at once.
                if (selfHeard || self.model.asking), PushToTalk.isStopPhrase(heard) {
                    voiceLog.notice("stop heard: silenced")
                    speaker.cancel(); model.interrupt(); model.settleInterrupted(); return
                }
                guard let command = WakeWord.parse(heard, learned: model.wakeLearned) else { voiceLog.notice("standby: not a wake phrase\(debug ? " [\(heard)]" : "", privacy: .public)"); return }
                if !selfHeard || command == .sleep { wake(command) }
            }
        }
    }

    private func wake(_ command: WakeCommand) {
        guard standby, !locked else { return }
        // While Jarvis waits on you to type, the wake word only stops speech; it never starts or ends anything.
        if model.waitingForYou { if command == .sleep { speaker.cancel() }; return }
        voiceLog.notice("wake: \(String(describing: command).prefix(while: { $0 != "(" }), privacy: .public)") // the command kind, never the words
        switch command {
        case .startNotes: toggleNoteTaking()
        case .stopNotes: return
        case .sleep: speaker.cancel(); model.interrupt(); model.settleInterrupted()
        case .listen: beginExchange(); speaker.enqueue("Yes?")
        case let .ask(question): beginExchange(); ask(question)
        }
    }

    /// True while a "Hey Jarvis" conversation is on (hands-free talk that ends by itself).
    private var exchange = false
    private var lastBusy = Date()
    private var exchangeStarted = Date()
    /// How long Jarvis waits for a follow-up after it has finished speaking.
    private static let followUpSeconds: TimeInterval = 8
    /// Follow-ups need no wake word, so anyone in the room could add one: a conversation never runs longer than this.
    private static let maxExchangeSeconds: TimeInterval = 120

    /// "Hey Jarvis" opens a short conversation. The mic switches to echo cancellation, as with TALK, so you can talk over
    /// Jarvis to interrupt it and ask follow-ups. A few quiet seconds after the last answer it goes back to standby.
    private func beginExchange() {
        speaker.cancel(); model.interrupt() // switching on echo cancellation restarts the audio engine
        pauseStandby()
        vad = listening()
        do { try mic.start(echoCancel: true) { [weak self] chunk in Task { @MainActor in self?.hear(chunk) } } } catch { resumeStandby(); return }
        live = true; exchange = true; model.live = true; model.voiceStatus = "Listening"; lastBusy = Date(); exchangeStarted = Date()
    }

    private func endExchangeIfQuiet() {
        guard exchange, live else { return }
        let busy = model.asking || speaker.pending > 0 || model.voiceStatus == "Hearing you" || model.voiceStatus == "Transcribing"
        if busy { lastBusy = Date() }
        let quiet = !busy && Date().timeIntervalSince(lastBusy) > Self.followUpSeconds
        // At the limit Jarvis stops listening for more, but lets the answer it is giving finish.
        let tooLong = !model.asking && speaker.pending == 0 && Date().timeIntervalSince(exchangeStarted) > Self.maxExchangeSeconds
        if quiet || tooLong { voiceLog.notice("conversation over"); toggleLive() }
    }

    private func ask(_ question: String) {
        guard !locked else { return } // nothing spoken is acted on while you are away
        speaker.cancel(); model.interrupt()
        Task {
            while model.asking { try? await Task.sleep(for: .milliseconds(50)) }
            model.question = SpeechScript.fixSpelling(question, model.spellings)
            ackIfSlow()
            await model.ask(speak: true)
        }
    }
}
