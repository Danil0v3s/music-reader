import AVFoundation
import Combine
import ScoreKit

/// Switches the shared audio session between listening (playback only) and practising (microphone on,
/// measurement mode so iOS doesn't apply voice processing or gain control to the cello).
enum AudioSessionMode {
    case playback, practice

    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            switch self {
            case .playback:
                try session.setCategory(.playback, mode: .default)
            case .practice:
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
            try session.setActive(true)
        } catch {
            print("Audio session: \(error)")
        }
    }
}

/// Plays a rendered schedule: the synth on one player node, metronome clicks on another (so the click
/// can be muted live), started on the same render time so they stay together.
@MainActor
final class ScorePlayer {
    enum State: Equatable { case stopped, rendering, playing(startedAt: Double), paused(at: Double) }

    let state = CurrentValueSubject<State, Never>(.stopped)
    var metronome = false { didSet { clickNode.volume = metronome ? 1 : 0 } }
    var musicVolume: Float = 1 { didSet { musicNode.volume = musicVolume } }
    /// Recorded cello notes; nil until loaded (or if the set is missing), and then the synth plays.
    var bank: SampleBank?
    var useSamples = true

    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private let clickNode = AVAudioPlayerNode()
    /// The samples were recorded in a dead room; a little room sound makes them natural.
    private let reverb = AVAudioUnitReverb()
    private let sampleRate = 44100.0
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var schedule: PlaybackSchedule?
    /// Schedule time at the start of the rendered buffers (playing from a bar).
    private var bufferStart = 0.0
    private var leadIn = 0.0
    private var generation = 0
    /// Host time the buffers start sounding at; position is measured from it on the host clock.
    private var startHostTime: UInt64 = 0

    init() {
        engine.attach(musicNode)
        engine.attach(clickNode)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 18
        engine.connect(musicNode, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(clickNode, to: engine.mainMixerNode, format: format)
        clickNode.volume = 0
    }

    /// Current position on the schedule's timeline (negative during a count-in).
    var currentTime: Double {
        switch state.value {
        case .playing:
            let now = mach_absolute_time()
            let elapsed = now > startHostTime ? AVAudioTime.seconds(forHostTime: now - startHostTime) : 0
            return bufferStart - leadIn + elapsed - outputLatency
        case .paused(let at): return at
        default: return 0
        }
    }

    /// Renders and starts playing `schedule` from `start` seconds, with `countInBeats` clicks first.
    func play(_ schedule: PlaybackSchedule, from start: Double = 0, countInBeats: Int = 0, session: AudioSessionMode = .playback) {
        stopNodes()
        generation += 1
        let gen = generation
        self.schedule = schedule
        state.send(.rendering)
        // Count-in at the tempo of the first beat interval.
        let beatLength = schedule.beats.count > 1 ? schedule.beats[1].time - schedule.beats[0].time : 0.75
        let countIn = (0..<countInBeats).map { -Double(countInBeats - $0) * beatLength }
        let leadIn = countIn.first.map { -$0 } ?? 0
        let sr = sampleRate
        let bank = useSamples ? bank : nil
        Task.detached(priority: .userInitiated) {
            session.activate()
            let synth = Synth(sampleRate: sr)
            let music = bank.map { synth.renderSampled(schedule, bank: $0, from: start, leadIn: leadIn) }
                ?? synth.renderMusic(schedule, from: start, leadIn: leadIn)
            let clicks = synth.renderClicks(schedule, from: start, countIn: countIn)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.start(music: music, clicks: clicks, from: start, leadIn: leadIn)
            }
        }
    }

    private func start(music: [Float], clicks: [Float], from start: Double, leadIn: Double) {
        guard let musicBuffer = buffer(music), let clickBuffer = buffer(clicks) else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("Audio engine: \(error)")
            state.send(.stopped)
            return
        }
        bufferStart = start
        self.leadIn = leadIn
        let gen = generation
        musicNode.scheduleBuffer(musicBuffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.generation, case .playing = self.state.value else { return }
                self.state.send(.stopped)
            }
        }
        clickNode.scheduleBuffer(clickBuffer, at: nil, options: [])
        // Start both a little ahead, at the same host time.
        startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08)
        let when = AVAudioTime(hostTime: startHostTime)
        musicNode.play(at: when)
        clickNode.play(at: when)
        state.send(.playing(startedAt: start))
    }

    func pause() {
        let t = currentTime
        stopNodes()
        state.send(.paused(at: max(0, t)))
    }

    func stop() {
        generation += 1
        stopNodes()
        state.send(.stopped)
    }

    /// What the listener hears lags the render clock by the output latency.
    private var outputLatency: Double { AVAudioSession.sharedInstance().outputLatency }

    private func stopNodes() {
        musicNode.stop()
        clickNode.stop()
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return b
    }
}

/// A looping reference tone for tuning to (the open strings).
@MainActor
final class DronePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let setup = DispatchQueue(label: "drone", qos: .userInitiated)
    private(set) var frequency: Double?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Rendering and starting the engine happen off the main thread: starting audio hardware can block.
    func play(_ frequency: Double) {
        stop()
        self.frequency = frequency
        let (engine, node, format) = (engine, node, format)
        setup.async {
            let samples = Synth(sampleRate: 44100).renderDrone(frequency: frequency)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            b.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            do { if !engine.isRunning { try engine.start() } } catch { return }
            node.scheduleBuffer(b, at: nil, options: .loops)
            node.play()
        }
    }

    func stop() {
        frequency = nil
        let node = node
        setup.async { node.stop() }
    }
}

/// Listens to the microphone and reports pitch readings on the main actor.
final class MicrophoneListener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "pitch", qos: .userInteractive)
    /// Session activation, engine start and stop, kept in order and off the main thread.
    private let setup = DispatchQueue(label: "microphone-setup", qos: .userInitiated)
    private var running = false
    var onReading: (@MainActor (PitchDetector.Reading?) -> Void)?
    #if DEBUG
    /// Debug only: readings come from this instead of the microphone (frequency, or nil for silence).
    @MainActor var simulate: (() -> Double?)?
    @MainActor private var simulationTimer: Timer?
    #endif

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts listening. Activating the audio session and starting the engine can block for a while (the
    /// hardware is being reconfigured), so it happens on a background queue; `completion` runs on the main
    /// actor with nil, or the error.
    @MainActor func start(completion: @escaping @MainActor (Error?) -> Void) {
        guard !running else { completion(nil); return }
        running = true
        #if DEBUG
        if let simulate {
            simulationTimer = Timer.scheduledTimer(withTimeInterval: 0.046, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    let f = simulate()
                    self?.onReading?(f.map { PitchDetector.Reading(frequency: $0, confidence: 0.95, level: 0.1) })
                }
            }
            completion(nil)
            return
        }
        #endif
        setup.async { [self] in
            do {
                AudioSessionMode.practice.activate()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else {
                    throw NSError(domain: "Microphone", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input."])
                }
                let detector = PitchDetector(sampleRate: format.sampleRate)
                let size = AVAudioFrameCount(detector.preferredBufferSize)
                input.installTap(onBus: 0, bufferSize: size, format: format) { [weak self] buffer, _ in
                    guard let self, let data = buffer.floatChannelData?[0] else { return }
                    let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                    self.queue.async {
                        let reading = detector.detect(samples)
                        let callback = self.onReading
                        Task { @MainActor in callback?(reading) }
                    }
                }
                try engine.start()
                Task { @MainActor in completion(nil) }
            } catch {
                Task { @MainActor in
                    self.running = false
                    completion(error)
                }
            }
        }
    }

    @MainActor func stop() {
        guard running else { return }
        running = false
        #if DEBUG
        if simulationTimer != nil {
            simulationTimer?.invalidate()
            simulationTimer = nil
            return
        }
        #endif
        setup.async { [engine] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
