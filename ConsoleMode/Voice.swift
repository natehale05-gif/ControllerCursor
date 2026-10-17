import AppKit
import AVFoundation
import Speech

/// Hold a button, talk, let go: Apple's speech recognition types what you said.
final class VoiceTyping {
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    private var latest = ""
    /// The user still wants to be listening (permission prompts can finish after the button is let go)
    private var wanted = false
    private var session = 0
    private(set) var isListening = false

    /// Live transcript while talking, and nil when finished
    var onUpdate: ((String?) -> Void)?
    var onMessage: ((String) -> Void)?
    /// Asked right before typing; return false to drop the text (e.g. a game came to the front)
    var shouldType: () -> Bool = { true }

    var isActive: Bool { wanted || isListening }

    func start() {
        guard !isListening, !wanted else { return }
        wanted = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.wanted else { return }
                guard status == .authorized else {
                    self.wanted = false
                    self.onMessage?("Allow Speech Recognition for Console Mode in System Settings → Privacy & Security")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard self.wanted else { return }
                        if granted { self.begin() } else {
                            self.wanted = false
                            self.onMessage?("Allow the Microphone for Console Mode in System Settings → Privacy & Security")
                        }
                    }
                }
            }
        }
    }

    private func begin(onDevice: Bool = true) {
        guard wanted, !isListening else { return }
        guard let recognizer else {
            wanted = false
            onMessage?("Speech recognition doesn't support your Mac's language")
            return
        }
        guard recognizer.isAvailable else {
            wanted = false
            onMessage?("Turn on Dictation in System Settings → Keyboard, then try again")
            return
        }
        // A fresh engine each time picks up mic changes (AirPods connecting, etc.)
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            wanted = false
            onMessage?("No microphone found")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(macOS 13.0, *) { req.addsPunctuation = true }
        // On-device is faster and private, but only works once macOS has downloaded the speech model
        let useOnDevice = onDevice && !onDeviceBroken && recognizer.supportsOnDeviceRecognition
        req.requiresOnDeviceRecognition = useOnDevice
        request = req
        latest = ""
        heardSomething = false
        session += 1
        let mySession = session

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            wanted = false
            onMessage?("Couldn't start the microphone")
            return
        }
        isListening = true
        onUpdate?("")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.session == mySession else { return }
                if let result {
                    self.heardSomething = true
                    self.latest = result.bestTranscription.formattedString
                    if self.isListening { self.onUpdate?(self.latest) }
                    if result.isFinal { self.deliver(mySession) }
                    return
                }
                guard let error else { return }
                if useOnDevice, !self.heardSomething, !Self.isNoSpeech(error) { self.onDeviceBroken = true }
                if self.isListening {
                    // Failed while still talking: retry with Apple's servers, or explain what's wrong
                    self.abort()
                    if useOnDevice, !self.heardSomething, self.wanted {
                        self.begin(onDevice: false)
                    } else {
                        self.wanted = false
                        self.onUpdate?(nil)
                        self.onMessage?(Self.explain(error))
                    }
                } else {
                    if !self.heardSomething, !Self.isNoSpeech(error) { self.onMessage?(Self.explain(error)) }
                    self.deliver(mySession)
                }
            }
        }
    }

    private var heardSomething = false
    /// The on-device model failed once; use Apple's servers for the rest of this run
    private var onDeviceBroken = false

    /// Tear down the current attempt without typing anything
    private func abort() {
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        session += 1
    }

    private static func isNoSpeech(_ error: Error) -> Bool {
        let e = error as NSError
        // "No speech detected" / cancelled
        return (e.domain == "kAFAssistantErrorDomain" && (e.code == 1110 || e.code == 216 || e.code == 203))
            || e.code == 301
    }

    private static func explain(_ error: Error) -> String {
        let e = error as NSError
        switch (e.domain, e.code) {
        case ("kAFAssistantErrorDomain", 1700), ("kLSRErrorDomain", 201), ("kAFAssistantErrorDomain", 1101):
            return "Turn on Dictation in System Settings → Keyboard, then try again"
        case ("kLSRErrorDomain", 102), ("kLSRErrorDomain", 300):
            return "macOS is still downloading the speech model. Try again in a minute"
        case ("kAFAssistantErrorDomain", 1107), ("kAFAssistantErrorDomain", 1100):
            return "Voice typing needs an internet connection right now"
        default:
            return "Voice typing didn't work: \(e.localizedDescription)"
        }
    }

    /// Stop listening; the text is typed as soon as the recognizer finishes the last words
    func stop() {
        wanted = false
        guard isListening else { return }
        isListening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        let mySession = session
        // Fallback in case the final result never arrives
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver(mySession) }
    }

    private var delivered = Set<Int>()

    private func deliver(_ mySession: Int) {
        guard !delivered.contains(mySession), mySession == session, !isListening else { return }
        delivered.insert(mySession)
        let text = latest.trimmingCharacters(in: .whitespaces)
        task?.finish()
        task = nil
        request = nil
        onUpdate?(nil)
        if !text.isEmpty, shouldType() { Output.shared.type(text) }
    }
}
