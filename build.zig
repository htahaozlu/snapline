//! Nokta build (Zig 0.17).
//!
//!   zig build                      libnokta.a + nokta.h → zig-out/
//!   zig build test                 core unit tests (pure + engine/mock) + C ABI check
//!   zig build app                  Snapline.app (Swift shell linked against libnokta.a, signed)
//!   zig build bench                benchmark harness (own test window only)
//!   zig build integrity            REA report on the built app → docs/INTEGRITY.md
//!   zig build -Dinert=true         libnokta-inert.a (tools/snapshot only; app/bench/integrity fail)
//!
//! The library is Debug by default; `-Drelease` selects ReleaseSmall.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });
    // Inert core for tools/snapshot: same ABI, no Accessibility / hotkeys / event tap / windows.
    // It has its own name (libnokta-inert.a), so `-lnokta` can never pick it up, and the steps
    // that build or measure Snapline.app refuse to run with it.
    const inert = b.option(bool, "inert", "Build an inert core with no system access (UI snapshot tool only)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "inert", inert);

    // ---- core library -----------------------------------------------------
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
    });
    core_mod.addOptions("build_options", options);
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = if (inert) "nokta-inert" else "nokta",
        .root_module = core_mod,
    });
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("core/include/nokta.h"), "nokta.h");
    lib.installHeader(b.path("core/include/module.modulemap"), "module.modulemap");
    b.installArtifact(lib);

    // ---- tests --------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("core/src/tests.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .link_libc = true,
    });
    const test_options = b.addOptions();
    test_options.addOption(bool, "inert", false);
    test_mod.addOptions("build_options", test_options);
    const unit = b.addTest(.{ .root_module = test_mod });
    const run_unit = b.addRunArtifact(unit);

    const abi_mod = b.createModule(.{ .target = target, .optimize = .debug, .link_libc = true });
    abi_mod.addCSourceFile(.{ .file = b.path("core/test/abi_check.c"), .flags = &.{ "-std=c11", "-Wall", "-Werror" } });
    abi_mod.addIncludePath(b.path("core/include"));
    const abi_obj = b.addObject(.{ .name = "abi_check", .root_module = abi_mod });

    const test_step = b.step("test", "Run core unit tests and the C ABI layout check");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&abi_obj.step);

    const app_step = b.step("app", "Build, bundle and sign build/Snapline.app");
    const bench_step = b.step("bench", "Run the benchmark harness (own test window only)");
    const integrity_step = b.step("integrity", "Generate docs/INTEGRITY.md from the built app with REA");

    // The inert core must never end up in Snapline.app, nor be benchmarked or reported as it.
    if (inert) {
        const fail = b.addFail("-Dinert=true builds the snapshot tool's core only; " ++
            "app, bench and integrity need the real core (drop -Dinert)");
        app_step.dependOn(&fail.step);
        bench_step.dependOn(&fail.step);
        integrity_step.dependOn(&fail.step);
        return;
    }

    // ---- app bundle (Swift shell) --------------------------------------------
    const app = b.addSystemCommand(&.{ "bash", "scripts/build-app.sh" });
    app.setEnvironmentVariable("NOKTA_OPTIMIZE", @tagName(optimize));
    // The install step below already built zig-out/ in this mode; the script reuses it.
    app.setEnvironmentVariable("NOKTA_CORE_INSTALLED", "1");
    app.step.dependOn(b.getInstallStep());
    app_step.dependOn(&app.step);

    // ---- benchmark harness ------------------------------------------------------
    const bench = b.addSystemCommand(&.{ "bash", "scripts/bench.sh" });
    bench.step.dependOn(&app.step);
    bench_step.dependOn(&bench.step);

    // ---- integrity report ------------------------------------------------------
    const integrity = b.addSystemCommand(&.{ "bash", "scripts/integrity.sh" });
    integrity.step.dependOn(&app.step);
    integrity_step.dependOn(&integrity.step);
}
