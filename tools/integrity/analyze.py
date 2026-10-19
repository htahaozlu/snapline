#!/usr/bin/env python3
"""Nokta integrity analysis. Always run as `python3 -I tools/integrity/analyze.py ...`.

Pure analysis of artefacts collected by scripts/integrity.sh (REA CLI JSON, otool, nm, codesign) plus
read-only inspection of the .app bundle. Writes a Markdown report and a JSON result; exit status 1
when any policy violation (FAIL) is found. Rules live in tools/integrity/policy.json.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import sys

STATUS_ORDER = {"FAIL": 0, "WARN": 1, "INFO": 2, "PASS": 3}


# ----------------------------------------------------------------------------------------------
def read_text(raw, name):
    try:
        with open(os.path.join(raw, name), errors="replace") as f:
            return f.read()
    except OSError:
        return None


def read_json(raw, name):
    t = read_text(raw, name)
    if not t or not t.strip():
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def esc(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def human(n):
    return f"{n / 1048576:.2f} MB" if n >= 1048576 else f"{n / 1024:.1f} KB"


def kv(text):
    out = {}
    for line in (text or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


class Report:
    def __init__(self):
        self.checks = []

    def add(self, cid, title, status, detail, evidence=None):
        self.checks.append({"id": cid, "title": title, "status": status, "detail": detail, "evidence": evidence or []})

    def count(self, status):
        return sum(1 for c in self.checks if c["status"] == status)


# ----------------------------------------------------------------------------------------------
def parse_otool_L(text):
    libs = []
    for line in (text or "").splitlines():
        if line.startswith(("\t", " ")) and "(" in line:
            libs.append(line.strip().split(" (")[0])
    return libs


NM_RE = re.compile(r"\(undefined\)\s+(?:weak\s+)?(?:private\s+)?external\s+(\S+)(?:\s+\((?:from ([^)]+)|dynamically looked up)\))?")


def parse_nm(text):
    syms = []
    for line in (text or "").splitlines():
        m = NM_RE.search(line)
        if m:
            syms.append((m.group(1), m.group(2) or "(flat / dynamic)"))
    return syms


def parse_rpaths(text):
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (\S+)", text or "")


def categorize_lib(path):
    if path.startswith("/System/Library/Frameworks/"):
        return "system framework"
    if path.startswith("/System/Library/PrivateFrameworks/"):
        return "PRIVATE framework"
    if path.startswith("/usr/lib/swift/"):
        return "Swift runtime (OS)"
    if path.startswith("/usr/lib/"):
        return "system library"
    return "NOT SYSTEM"


def short_lib(path):
    m = re.search(r"/([^/]+)\.framework/", path)
    return m.group(1) if m else os.path.basename(path)


def walk_plist(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield (f"{prefix}{k}", k, v)
            yield from walk_plist(v, f"{prefix}{k}.")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from walk_plist(v, f"{prefix}[{i}].")


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


# ----------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()

    with open(a.policy) as f:
        policy = json.load(f)
    meta = kv(read_text(a.raw, "meta.txt"))
    exe = meta.get("exe") or os.path.join(a.app, "Contents", "MacOS", "Snapline")
    rep = Report()

    # ---- subject --------------------------------------------------------------------------------
    subject = {"app": a.app, "exe": exe, "exe_bytes": os.path.getsize(exe), "exe_sha256": sha256(exe),
               "archs": meta.get("archs", "?")}
    rea_macho = read_json(a.raw, "rea-macho.json")
    rea_sig = read_json(a.raw, "rea-signature.json")
    rea_plist = read_json(a.raw, "rea-plist.json")
    rm = (rea_macho or {}).get("normalized_result") or {}
    if rm:
        bm = ((rm.get("build_metadata") or {}).get("items") or [{}])[0]
        subject.update(uuid=rm.get("uuid"), min_os=bm.get("minimum_os"), sdk=bm.get("sdk"))
    cs_dv = read_text(a.raw, "codesign-dv.txt") or ""

    # ---- 1. signature -----------------------------------------------------------------------------
    verify_rc = meta.get("codesign_verify_rc", "?")
    rep.add("sig-valid", "Code signature verifies (`codesign --verify --strict --deep`)",
            "PASS" if verify_rc == "0" else "FAIL", "valid on disk" if verify_rc == "0" else f"exit {verify_rc}",
            [(read_text(a.raw, "codesign-verify.txt") or "").strip()])

    flags = re.search(r"flags=(0x[0-9a-f]+)\(([^)]*)\)", cs_dv)
    hardened = bool(flags and "runtime" in flags.group(2))
    rep.add("hardened-runtime", "Hardened runtime enabled", "PASS" if hardened else "FAIL",
            f"CodeDirectory flags {flags.group(1)}({flags.group(2)})" if flags else "no CodeDirectory flags found")

    ent_text = (read_text(a.raw, "entitlements.txt") or "").strip()
    ent_keys = re.findall(r"<key>([^<]+)</key>", ent_text)
    bad_ent = [k for k in ent_keys if k not in policy.get("allowed_entitlement_keys", [])]
    rep.add("entitlements", "No entitlements", "PASS" if not bad_ent else "FAIL",
            "none (empty entitlement blob)" if not ent_keys else "entitlements present: " + ", ".join(ent_keys),
            [f"entitlement key `{k}`" for k in ent_keys])

    dr = (re.search(r"designated => (.*)", read_text(a.raw, "codesign-dr.txt") or "") or [None, ""])[1].strip()
    adhoc = "Signature=adhoc" in cs_dv
    authorities = re.findall(r"^Authority=(.*)$", cs_dv, re.M)
    ident = (re.search(r"^Identifier=(.*)$", cs_dv, re.M) or [None, "?"])[1]
    stable_dr = bool(re.search(r'identifier ".+" and certificate root = H"[0-9a-f]{40}"', dr)) or "anchor apple generic" in dr
    if adhoc:
        rep.add("identity", "Stable signing identity", "WARN",
                "ad-hoc signature: the designated requirement is the cdhash, so the Accessibility grant is lost on every build",
                [f"designated requirement: {dr}"])
    else:
        rep.add("identity", "Stable signing identity", "PASS" if stable_dr else "WARN",
                f"identifier `{ident}`, authority {', '.join(authorities) or '?'}",
                [f"designated requirement: {dr}"])

    # ---- 2. linked libraries --------------------------------------------------------------------
    deps = {}  # path -> set(arch)
    for fn in sorted(os.listdir(a.raw)):
        m = re.match(r"otool-libs\.(.+)\.txt$", fn)
        if m:
            for lib in parse_otool_L(read_text(a.raw, fn)):
                deps.setdefault(lib, set()).add(m.group(1))
    allowed = tuple(policy["allowed_dylib_prefixes"])
    non_system = sorted(l for l in deps if not l.startswith(allowed))
    rep.add("system-only-libs", "Only system libraries are linked (nothing bundled)", "PASS" if not non_system else "FAIL",
            f"{len(deps)} libraries, all under {' or '.join(allowed)}" if not non_system else "non-system: " + ", ".join(non_system))
    hits = {}
    for rule in policy["deny_dylib"]:
        rx = re.compile(rule["regex"])
        found = sorted(l for l in deps if rx.search(l))
        if found:
            hits[rule["id"]] = (rule["why"], found)

    # ---- 3. symbols -------------------------------------------------------------------------------
    syms = []  # (name, lib)
    for fn in sorted(os.listdir(a.raw)):
        if re.match(r"nm-u\..+\.txt$", fn):
            syms += parse_nm(read_text(a.raw, fn))
    rea_imports = [(i.get("name"), i.get("source") or "?") for i in ((rm.get("imports") or {}).get("items") or []) if i.get("name")]
    all_syms = sorted(set(syms) | set(rea_imports))
    sym_hits, watch_hits = {}, {}
    for rule in policy["deny_symbol"]:
        rx = re.compile(rule["regex"])
        found = sorted({n for n, _ in all_syms if rx.search(n)})
        if found:
            sym_hits[rule["id"]] = (rule["why"], found)
    for rule in policy["watch_symbol"]:
        rx = re.compile(rule["regex"])
        found = sorted({n for n, _ in all_syms if rx.search(n)})
        if found:
            watch_hits[rule["id"]] = (rule["why"], found)

    def ev(group_dylib, group_sym):
        out = []
        for gid in group_dylib:
            if gid in hits:
                out.append(f"linked: {', '.join(hits[gid][1])}  ({hits[gid][0]})")
        for gid in group_sym:
            if gid in sym_hits:
                out.append(f"{gid}: {', '.join(sym_hits[gid][1][:12])}{' ...' if len(sym_hits[gid][1]) > 12 else ''}  ({sym_hits[gid][0]})")
        return out

    net_ids = [i for i in sym_hits if i.startswith("net-")]
    e = ev(["network-framework"], net_ids)
    rep.add("no-network", "No network surface (no sockets / CFNetwork / URLSession / Network.framework)", "PASS" if not e else "FAIL",
            f"0 of {len(all_syms)} imported symbols and 0 of {len(deps)} linked libraries match" if not e else f"{len(e)} rule group(s) matched", e)
    e = ev(["private-framework"], ["private-api"])
    rep.add("no-private", "No private frameworks or private SkyLight / CGS / HIServices symbols", "PASS" if not e else "FAIL",
            "none found" if not e else f"{len(e)} rule group(s) matched", e)
    e = ev(["updater"], ["updater"])
    rep.add("no-updater", "No updater framework (Sparkle and the like)", "PASS" if not e else "FAIL",
            "none found" if not e else f"{len(e)} rule group(s) matched", e)
    e = ev(["non-system-dylib"], [])
    if e:
        rep.add("no-rpath-libs", "No @rpath / @executable_path libraries", "FAIL", "relative dylib references", e)

    for wid, (why, names) in sorted(watch_hits.items()):
        rep.add(f"watch-{wid}", f"API surface to review: {wid}", "WARN", why, [", ".join(names[:12]) + (" ..." if len(names) > 12 else "")])

    rpaths = []
    for fn in sorted(os.listdir(a.raw)):
        if re.match(r"otool-load\..+\.txt$", fn):
            rpaths += parse_rpaths(read_text(a.raw, fn))
    rpaths = sorted(set(rpaths))
    bad_rp = [r for r in rpaths if not r.startswith(("/usr/lib/", "/System/"))]
    rep.add("rpaths", "LC_RPATH entries", "WARN" if bad_rp else "INFO",
            ", ".join(rpaths) if rpaths else "none", [f"non-system rpath: {r}" for r in bad_rp])

    # ---- 4. Info.plist ----------------------------------------------------------------------------
    plist_path = os.path.join(a.app, "Contents", "Info.plist")
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    key_rx = re.compile(policy["deny_plist_key"])
    val_rx = re.compile(policy["deny_plist_value"])
    plist_hits = []
    for path, key, val in walk_plist(info):
        if key_rx.search(key):
            plist_hits.append(f"key `{path}`")
        if isinstance(val, str) and val_rx.search(val):
            plist_hits.append(f"value of `{path}` looks like a URL: {val}")
    rep.add("plist-no-urls", "Info.plist has no URL / feed / updater / ATS keys", "PASS" if not plist_hits else "FAIL",
            f"{len(info)} top-level keys, none match" if not plist_hits else f"{len(plist_hits)} hit(s)", plist_hits)

    # ---- 5. bundle contents -------------------------------------------------------------------------
    files, machos, forbidden = [], [], []
    for root, dirs, fnames in os.walk(a.app):
        dirs.sort()
        for fn in sorted(fnames):
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, a.app)
            files.append((rel, os.path.getsize(p)))
            if is_macho(p):
                machos.append(rel)
        for d in dirs:
            rel = os.path.relpath(os.path.join(root, d), a.app)
            if rel in policy["forbidden_bundle_paths"]:
                forbidden.append(rel)
    rep.add("bundle-single-binary", "Bundle contains exactly one Mach-O and no frameworks / helpers / plug-ins",
            "PASS" if len(machos) == 1 and not forbidden else "FAIL",
            f"{len(files)} files, Mach-O: {', '.join(machos)}" if not forbidden else "forbidden directories: " + ", ".join(forbidden))

    # ---- 6. URL literals in the binary ---------------------------------------------------------------
    with open(exe, "rb") as f:
        blob = f.read()
    urls = sorted({m.group(0).decode("ascii", "replace") for m in re.finditer(rb"[A-Za-z][A-Za-z0-9+.-]{1,12}://[^\s\"'<>\x00-\x20\x7f-\xff]{3,200}", blob)})
    ignore = [re.compile(r) for r in policy.get("url_literal_ignore", [])]
    benign = [u for u in urls if any(r.search(u) for r in ignore)]
    urls = [u for u in urls if u not in benign]
    rep.add("url-literals", "URL literals in the binary", "PASS" if not urls else "WARN",
            ("none" if not benign else f"none ({len(benign)} known-benign compiler / plist doc string(s) ignored)") if not urls
            else f"{len(urls)} found (review: they may be doc strings)", urls[:10])

    # ---- 7. REA cross-check ---------------------------------------------------------------------------
    rea_ok = bool(rea_macho and rea_sig and rea_plist)
    if not rea_ok:
        missing = [n for n, o in (("inspect-macho", rea_macho), ("inspect-signature", rea_sig), ("inspect-plist", rea_plist)) if not o]
        status = "FAIL" if meta.get("require_rea") == "1" else "WARN"
        rep.add("rea", "REA cross-check", status, "unavailable: " + ", ".join(missing) + " (see raw/rea-*.err); native tools still decided every check above")
    else:
        problems = []
        rd = {i["path"] for i in (rm.get("dependencies") or {}).get("items") or []}
        if rd and rd != set(deps):
            problems.append(f"dependency lists differ: only REA {sorted(rd - set(deps))}, only otool {sorted(set(deps) - rd)}")
        rs = rea_sig.get("normalized_result") or {}
        if rs.get("identifier") != ident:
            problems.append(f"signature identifier differs: REA {rs.get('identifier')} vs codesign {ident}")
        if bool(rs.get("hardened_runtime")) != hardened:
            problems.append(f"hardened runtime differs: REA {rs.get('hardened_runtime')} vs codesign {hardened}")
        if rs.get("entitlements") not in (None, {}, []) and not ent_keys:
            problems.append(f"REA reports entitlements {rs.get('entitlements')} but codesign shows none")
        rp = ((rea_plist.get("normalized_result") or {}).get("value")) or {}
        if rp and set(rp) != set(info):
            problems.append("Info.plist key sets differ between REA and plistlib")
        rep.add("rea", "REA (rea-agents@%s) agrees with otool / codesign / plistlib" % meta.get("rea_version", "?"),
                "PASS" if not problems else "WARN",
                "inspect-macho, inspect-signature and inspect-plist results match the native tools" if not problems else f"{len(problems)} difference(s)",
                problems)

    # ---- result ----------------------------------------------------------------------------------------
    fails, warns = rep.count("FAIL"), rep.count("WARN")
    verdict = "FAIL" if fails else "PASS"

    # ---- markdown ----------------------------------------------------------------------------------------
    md = []
    md.append("# Nokta integrity report\n")
    md.append(f"**Verdict: {verdict}** — {fails} violation(s), {warns} warning(s), {rep.count('PASS')} passed.\n")
    md.append("Generated by `scripts/integrity.sh` from the built app. Nothing here is hand-written; regenerate with `zig build integrity`.\n")
    md.append("| | |\n|---|---|")
    md.append(f"| Date (UTC) | {meta.get('generated', '?')} |")
    md.append(f"| App | `{os.path.relpath(a.app)}` |")
    md.append(f"| Executable | {human(subject['exe_bytes'])} ({subject['exe_bytes']} bytes), `{subject['archs']}` |")
    md.append(f"| SHA-256 | `{subject['exe_sha256']}` |")
    if subject.get("uuid"):
        md.append(f"| Mach-O UUID | `{subject['uuid']}` |")
        md.append(f"| Minimum macOS / SDK | {subject.get('min_os')} / {subject.get('sdk')} |")
    md.append(f"| Tools | REA `rea-agents@{meta.get('rea_version', '?')}`, otool, nm, codesign (Xcode CLT) |")
    md.append("")

    md.append("## Checks\n")
    md.append("| Result | Check | Detail |\n|---|---|---|")
    for c in sorted(rep.checks, key=lambda c: (STATUS_ORDER[c["status"]], c["id"])):
        md.append(f"| **{c['status']}** | {esc(c['title'])} | {esc(c['detail'])} |")
    md.append("")
    ev_checks = [c for c in rep.checks if c["evidence"] and c["status"] in ("FAIL", "WARN")]
    if ev_checks:
        md.append("### Evidence for failures and warnings\n")
        for c in ev_checks:
            md.append(f"**{c['status']} — {c['title']}**\n")
            for line in c["evidence"]:
                md.append(f"- {line}")
            md.append("")

    md.append("## Linked libraries\n")
    md.append("| Library | Kind | Arch |\n|---|---|---|")
    for lib in sorted(deps):
        md.append(f"| `{lib}` | {categorize_lib(lib)} | {', '.join(sorted(deps[lib]))} |")
    md.append("")
    fw = sorted({short_lib(l) for l in deps if ".framework/" in l})
    md.append(f"System frameworks ({len(fw)}): {', '.join(fw)}.\n")

    md.append("## Imported symbols by library\n")
    by_lib = {}
    for n, l in all_syms:
        by_lib.setdefault(l, []).append(n)
    md.append("| Library | Imported symbols |\n|---|---|")
    for l, names in sorted(by_lib.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        md.append(f"| {esc(l)} | {len(names)} |")
    md.append("")
    md.append("### System API surface the binary reaches for (informational)\n")
    families = [
        ("Accessibility (window access)", r"^_AX"),
        ("Global hotkeys (Carbon)", r"^_(RegisterEventHotKey|UnregisterEventHotKey|InstallEventHandler|InstallApplicationEventHandler|GetApplicationEventTarget|GetEventDispatcherTarget|GetEventParameter|RemoveEventHandler)"),
        ("Event tap / CGEvent", r"^_CGEvent"),
        ("Displays", r"^_(CGDisplay|CGMainDisplayID|CGGetActiveDisplayList|CGGetOnlineDisplayList|CGDisplayRegisterReconfigurationCallback)"),
        ("Window list", r"^_CGWindow"),
        ("Login item", r"SMAppService|^_SM[A-Z]"),
        ("Logging", r"^_os_log|^_os_signpost"),
    ]
    md.append("| Family | Symbols |\n|---|---|")
    for title, rx in families:
        found = sorted({n for n, _ in all_syms if re.search(rx, n)})
        md.append(f"| {title} | {esc(', '.join(f'`{n}`' for n in found)) if found else '-'} |")
    md.append("")

    md.append("## Info.plist\n")
    md.append("| Key | Value |\n|---|---|")
    for k in sorted(info):
        md.append(f"| `{k}` | {esc(info[k])} |")
    md.append("")

    md.append("## Signature\n")
    md.append("```")
    md.append(cs_dv.strip())
    md.append(f"designated => {dr}")
    md.append("```\n")
    md.append(f"Entitlements: {'none' if not ent_keys else ', '.join(ent_keys)}.\n")

    md.append("## Bundle files\n")
    md.append("| File | Size |\n|---|---|")
    for rel, size in files:
        md.append(f"| `{rel}` | {human(size)} |")
    md.append(f"\nTotal {human(sum(s for _, s in files))}.\n")

    with open(a.out, "w") as f:
        f.write("\n".join(md) + "\n")
    with open(a.json, "w") as f:
        json.dump({"verdict": verdict, "violations": fails, "warnings": warns, "subject": subject, "checks": rep.checks}, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"integrity: {verdict} — {fails} violation(s), {warns} warning(s), {rep.count('PASS')} passed")
    for c in sorted(rep.checks, key=lambda c: (STATUS_ORDER[c["status"]], c["id"])):
        if c["status"] in ("FAIL", "WARN"):
            print(f"  [{c['status']}] {c['title']}: {c['detail']}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
