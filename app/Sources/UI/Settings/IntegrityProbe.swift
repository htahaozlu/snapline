import AppKit
import Darwin
import Security

/// Live self-measurements for Settings › About (DESIGN §8). Public kernel/Security APIs only, no
/// command-line tools, no timers. `sample()` is a handful of syscalls; the code signature is read
/// once per process.
enum IntegrityProbe {
    /// DESIGN §1: phys_footprint idle target.
    static let memoryBudget: UInt64 = 12 * 1024 * 1024

    struct Sample {
        var footprint: UInt64?
        var resident: UInt64?
        var ipSockets: Int?
        var threads: Int?
        var cpuSeconds: Double
        var uptime: TimeInterval?
    }

    static func sample() -> Sample {
        Sample(footprint: footprint(), resident: residentSize(), ipSockets: ipSocketCount(),
               threads: threadCount(), cpuSeconds: cpuSeconds(),
               uptime: processStart.map { Date().timeIntervalSince($0) })
    }

    // MARK: memory

    /// `task_info(TASK_VM_INFO).phys_footprint` — the number Activity Monitor calls "Memory".
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// `MACH_TASK_BASIC_INFO.resident_size` (RSS).
    static func residentSize() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    // MARK: sockets, threads, CPU

    /// Open AF_INET/AF_INET6 sockets of this process: `proc_pidinfo(PROC_PIDLISTFDS)` +
    /// `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. nil if the kernel refused the query.
    static func ipSocketCount() -> Int? {
        let pid = getpid()
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdSize + 8)
        let bytes = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard bytes >= 0 else { return nil }
        var count = 0
        for fd in fds.prefix(Int(bytes) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let family = info.psi.soi_family
            if family == AF_INET || family == AF_INET6 { count += 1 }
        }
        return count
    }

    static func threadCount() -> Int? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }

    /// User + system CPU time since launch (`getrusage(RUSAGE_SELF)`).
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// Process start time (`proc_pidinfo(PROC_PIDTBSDINFO)`), read once.
    static let processStart: Date? = {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    }()

    // MARK: code signature

    struct Signature {
        enum Kind { case unsigned, adhoc, signed }
        var kind: Kind = .unsigned
        var identifier: String?
        var authority: String?
        var teamID: String?
        var hardenedRuntime = false
        /// Sorted "key" → printable value.
        var entitlements: [(key: String, value: String)] = []

        var networkEntitlements: [String] {
            entitlements.map(\.key).filter { $0.hasPrefix("com.apple.security.network.") }
        }

        /// "Nokta Local Dev Signing · hardened runtime"
        var summary: String {
            var parts: [String] = []
            switch kind {
            case .unsigned: parts.append("Unsigned development build")
            case .adhoc: parts.append("Ad-hoc")
            case .signed: parts.append(authority ?? teamID ?? "Signed")
            }
            if kind != .unsigned { parts.append(hardenedRuntime ? "hardened runtime" : "no hardened runtime") }
            return parts.joined(separator: " · ")
        }
    }

    /// `SecCodeCopySelf` → `SecCodeCopySigningInformation`: entitlements, flags, leaf authority.
    static let signature: Signature = {
        var result = Signature()
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return result }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return result }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return result }

        result.identifier = info[kSecCodeInfoIdentifier as String] as? String
        guard result.identifier != nil else { return result } // unsigned
        let flags = SecCodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        result.hardenedRuntime = flags.contains(.runtime)
        result.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            result.authority = SecCertificateCopySubjectSummary(leaf) as String?
            result.kind = .signed
        } else {
            result.kind = flags.contains(.adhoc) ? .adhoc : .signed
        }
        if let dict = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            result.entitlements = dict.keys.sorted().map { ($0, printable(dict[$0])) }
        }
        return result
    }()

    private static func printable(_ value: Any?) -> String {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let s as String: return s
        case let a as [Any]: return a.map { printable($0) }.joined(separator: ", ")
        case nil: return ""
        default: return String(describing: value!)
        }
    }

    // MARK: app identity

    /// "0.2.0": the bundle's version, `nk_version_string` when the bundle carries none (a
    /// development build keeps its `__VERSION__` placeholder).
    static var shortVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (short?.hasPrefix("__") == false ? short : nil) ?? NoktaEngine.version
    }

    /// "0.2.0 (14)": version and build, for the report.
    static var versionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, !build.hasPrefix("__"), !build.isEmpty { return "\(shortVersion) (\(build))" }
        return shortVersion
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var lsofCommand: String { "lsof -a -i -p \(getpid())" }

    // MARK: report

    /// Plain-text report for "Copy Report" (About).
    static func report(app: AppController) -> String {
        let s = sample()
        let stats = app.engine.stats()
        let sig = signature
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        lines.append("\(Product.name) \(versionString) · \(architecture) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Measured \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("MEASURED NOW")
        lines.append("Memory: footprint \(Measure.megabytes(s.footprint)) · RSS \(Measure.megabytes(s.resident)) · target \(Measure.megabytes(memoryBudget)) footprint")
        if stats.snaps == 0 {
            lines.append("Last snap: — (no snaps yet)")
        } else {
            lines.append("Last snap: \(Measure.milliseconds(stats.last_latency_ns)) · p50 \(Measure.milliseconds(stats.p50_latency_ns)) · p95 \(Measure.milliseconds(stats.p95_latency_ns)) · max \(Measure.milliseconds(stats.max_latency_ns)) · n = \(stats.snaps) · failures \(stats.failures)")
        }
        lines.append("  (trigger → frame set, AX call returned; screen refresh not included)")
        lines.append("IP sockets open now: \(s.ipSockets.map(String.init) ?? "unavailable")")
        lines.append("Since launch: CPU \(Measure.cpu(s.cpuSeconds)) over \(Measure.duration(s.uptime)) · \(s.threads.map { "\($0) threads" } ?? "threads unavailable")")
        lines.append("Engine: \(engineState(app)) · shortcuts \(stats.hotkeys_bound) bound, \(stats.hotkeys_failed) failed · drag tap \(stats.event_tap_active ? "active" : "off") · displays \(stats.displays)")
        lines.append("")
        lines.append("BY DESIGN")
        lines.append("Accessibility: \(app.isTrusted ? "Granted" : "Not granted")")
        lines.append("Network entitlements: \(sig.networkEntitlements.isEmpty ? "None" : sig.networkEntitlements.joined(separator: ", "))")
        lines.append("Telemetry: None")
        lines.append("Updates: Manual. \(Product.name) never checks online.")
        lines.append("Entitlements: \(sig.entitlements.isEmpty ? "None" : "")")
        for e in sig.entitlements { lines.append("  \(e.key) = \(e.value)") }
        lines.append("Signature: \(sig.summary)")
        lines.append("Check it yourself: \(lsofCommand)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func engineState(_ app: AppController) -> String {
        if app.paused { return "Paused" }
        switch app.engineResult {
        case .ok: return "Running"
        case .eventTap: return "Running, drag snapping unavailable"
        case .notTrusted: return "Waiting for Accessibility permission"
        case .notStarted: return "Not running"
        default: return "Not running (\(app.engineResult.message))"
        }
    }
}

/// Number formatting shared by About and the report. Units are binary megabytes, like Activity
/// Monitor.
enum Measure {
    static func megabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// The number `megabytes` prints, for comparisons that must agree with the text (12.03 prints
    /// as 12.0 and is not over 12).
    static func printedMegabytes(_ bytes: UInt64) -> Double {
        Double(String(format: "%.1f", Double(bytes) / 1_048_576)) ?? 0
    }

    static func spokenMegabytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        return String(format: "%.1f megabytes", Double(bytes) / 1_048_576)
    }

    /// < 10 ms with one decimal, otherwise whole milliseconds.
    static func millisecondsValue(_ ns: UInt64) -> String {
        let ms = Double(ns) / 1e6
        return ms < 10 ? String(format: "%.1f", ms) : String(format: "%.0f", ms)
    }

    static func milliseconds(_ ns: UInt64) -> String { millisecondsValue(ns) + " ms" }

    static func spokenMilliseconds(_ ns: UInt64) -> String { millisecondsValue(ns) + " milliseconds" }

    static func cpu(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }

    static func sockets(_ count: Int?) -> String {
        guard let count else { return "sockets unavailable" }
        return count == 1 ? "1 socket" : "\(count) sockets"
    }
}
