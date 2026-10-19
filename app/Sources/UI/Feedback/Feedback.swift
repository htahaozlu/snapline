import AppKit
import AudioToolbox

/// Sound + haptic feedback (DESIGN §6). Owned by the visual work package; frozen API:
/// `init(prefs:)`, `zoneEntered`, `snapped`, `failed`, `preview`.
///
/// Sound is off by default (`prefs.soundEnabled`); sounds are synthesized on first use, written
/// once to ~/Library/Caches/com.htahaozlu.nokta/sounds/*.wav and played as system sounds (alert
/// volume and output device; no AVAudioEngine). Haptics (`prefs.hapticsEnabled`, default on)
/// fire only when a drag zone is captured or changes.
final class Feedback {
    private let prefs: Preferences
    private let bank = SoundBank()
    private var lastSound: CFTimeInterval = -1
    private var lastHaptic: CFTimeInterval = -1

    static let soundInterval: CFTimeInterval = 0.090
    static let hapticInterval: CFTimeInterval = 0.080

    /// Test seams: clock, sound sink and haptic sink (nil → the real system calls).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    var soundSink: ((SoundSynth.Spec) -> Void)?
    var hapticSink: (() -> Void)?

    init(prefs: Preferences) { self.prefs = prefs }

    /// Drag zone captured / changed → `.alignment` haptic (≤ 1 per 80 ms). No sound.
    func zoneEntered(_ event: NoktaEvent) {
        guard prefs.hapticsEnabled, event.kind == .previewShow else { return }
        let now = clock()
        guard lastHaptic < 0 || now - lastHaptic >= Self.hapticInterval else { return }
        lastHaptic = now
        if let hapticSink { hapticSink(); return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Drag commit → `tick`, keyboard/menu snap → `tick.soft`; pitch follows the zone size.
    func snapped(_ event: NoktaEvent) {
        guard prefs.soundEnabled, event.kind == .snapped else { return }
        let size = Self.size(for: event)
        play(event.source == .drag ? SoundSynth.tick(size) : SoundSynth.tickSoft(size))
    }

    /// Blocked → `thud`.
    func failed(_ event: NoktaEvent) {
        guard prefs.soundEnabled, event.kind == .failed, HUDText.blockedTitle(event.result) != nil else { return }
        play(SoundSynth.thud)
    }

    /// Settings/Onboarding preview (`ready`), plays even if Nokta's sound is off. Still silent
    /// when macOS "Play user interface sound effects" is off, so the preview never promises a
    /// sound snaps will not make.
    func preview() {
        play(SoundSynth.ready)
    }

    /// macOS "Play user interface sound effects". Read-only: the `com.apple.systemsound` domain
    /// first, then the standard/global lookup; on when neither has the key (P: device-verify
    /// which domain a given macOS version writes).
    static var systemUISoundsEnabled: Bool {
        let key = "com.apple.sound.uiaudio.enabled"
        if let v = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: key) as? NSNumber { return v.boolValue }
        if let v = UserDefaults.standard.object(forKey: key) as? NSNumber { return v.boolValue }
        return true
    }

    private func play(_ spec: SoundSynth.Spec) {
        guard Self.systemUISoundsEnabled else { return }
        let now = clock()
        guard lastSound < 0 || now - lastSound >= Self.soundInterval else { return } // tighter → dropped
        lastSound = now
        if let soundSink { soundSink(spec); return }
        bank.play(spec)
    }

    /// Pitch class: the action's size when it has one, else the frame's share of its screen.
    static func size(for e: NoktaEvent) -> SoundSynth.Size {
        if let a = e.action {
            switch a {
            case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
                return [SoundSynth.Size.half, .twoThirds, .third][Int(e.cycle) % 3]
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarter
            case .firstThird, .centerThird, .lastThird: return .third
            case .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: return .twoThirds
            case .maximize, .almostMaximize: return .maximize
            case .center, .restore, .nextDisplay, .prevDisplay: break
            }
        }
        guard let screen = Screens.screen(for: e.displayID) ?? NSScreen.main else { return .half }
        let area = screen.visibleFrame.width * screen.visibleFrame.height
        let share = area > 0 ? (e.rect.width * e.rect.height) / area : 0.5
        switch share {
        case 0.8...: return .maximize
        case 0.55...: return .twoThirds
        case 0.4...: return .half
        case 0.28...: return .third
        default: return .quarter
        }
    }
}

/// Lazily synthesized sound files + system sound ids.
final class SoundBank {
    private var ids: [String: SystemSoundID] = [:]
    private var fallbacks: [String: NSSound] = [:]
    /// Bump when the synthesis changes so cached files are rewritten.
    static let version = 1

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(Product.bundleID)/sounds", isDirectory: true)
    }

    deinit { ids.values.forEach { AudioServicesDisposeSystemSoundID($0) } }

    func play(_ spec: SoundSynth.Spec) {
        if let id = ids[spec.name] { AudioServicesPlaySystemSound(id); return }
        if let s = fallbacks[spec.name] { s.stop(); s.play(); return }
        let data = SoundSynth.wav(SoundSynth.render(spec))
        if let url = write(data, name: spec.name) {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError {
                ids[spec.name] = id
                AudioServicesPlaySystemSound(id)
                return
            }
        }
        if let s = NSSound(data: data) {
            fallbacks[spec.name] = s
            s.play()
        }
    }

    /// Writes the WAV once (reused while its size matches). Not in a bench or preview mode, which
    /// writes nothing outside its throwaway preferences: the sound then plays from memory.
    private func write(_ data: Data, name: String) -> URL? {
        guard !Preferences.systemWritesDisabled, let dir = Self.directory else { return nil }
        let url = dir.appendingPathComponent("\(name)-v\(Self.version).wav")
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path), (attrs[.size] as? NSNumber)?.intValue == data.count {
            return url
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
