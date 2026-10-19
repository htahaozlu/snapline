import Foundation

// Test hooks of the inert core (core/src/inert.zig; not in nokta.h, absent from the real core).
// Resolved with dlsym so they are called with the C convention; a missing hook is a test failure,
// never a silent pass.

enum InertCore {
    /// `nk_inert_counters`: what a live app would have done with Carbon so far.
    struct Counters: Equatable {
        var binds: UInt32 = 0, registered: UInt32 = 0, unregistered: UInt32 = 0, refused: UInt32 = 0
        /// Registrations alive now.
        var live: Int { Int(registered) - Int(unregistered) }

        static func - (a: Counters, b: Counters) -> Counters {
            Counters(binds: a.binds &- b.binds, registered: a.registered &- b.registered,
                     unregistered: a.unregistered &- b.unregistered, refused: a.refused &- b.refused)
        }
    }

    private typealias CountersFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>) -> Void
    private typealias SetTakenFn = @convention(c) (UInt32, UInt32, Bool) -> Bool

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static let countersFn = symbol("nk_inert_counters", as: CountersFn.self)
    private static let setTakenFn = symbol("nk_inert_set_taken", as: SetTakenFn.self)

    static var available: Bool { countersFn != nil && setTakenFn != nil }

    static func counters(_ engine: NoktaEngine) -> Counters {
        var raw = [UInt32](repeating: 0, count: 4)
        raw.withUnsafeMutableBufferPointer { countersFn?(engine.core, $0.baseAddress!) }
        return Counters(binds: raw[0], registered: raw[1], unregistered: raw[2], refused: raw[3])
    }

    /// Marks a combination as held by "another app" (registering it then fails), or frees it.
    @discardableResult
    static func setTaken(_ s: Shortcut, _ on: Bool) -> Bool { setTakenFn?(s.keyCode, s.mods, on) ?? false }
}

/// A failed or passed check, printed as it happens; `finish` prints the summary and returns the verdict.
final class Checks {
    private let name: String
    private(set) var count = 0
    private(set) var failures: [String] = []

    init(_ name: String) { self.name = name }

    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        count += 1
        if !ok {
            let text = what()
            failures.append(text)
            print("  FAIL \(text)")
        }
    }

    func finish() -> Bool {
        if failures.isEmpty {
            print("\(name): OK (\(count) checks)")
            return true
        }
        print("\(name): FAIL (\(failures.count) of \(count) checks)")
        return false
    }
}

/// Runs the main run loop briefly so `DispatchQueue.main.async` work (focus fix-ups, coalesced
/// refreshes, a closed window's clean-up) happens, like it would between two key presses.
/// `run(until:)` alone returns at once when the run loop has no source or timer — then queued
/// blocks ran later, after a test's AppController was gone (an intermittent crash in
/// `windowClosed`). A timer keeps the loop running to the deadline, so the queue is drained.
func settle(_ seconds: TimeInterval = 0.05) {
    let deadline = Date().addingTimeInterval(seconds)
    let keepAlive = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
    RunLoop.main.add(keepAlive, forMode: .default)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
    keepAlive.invalidate()
}
