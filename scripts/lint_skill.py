#!/usr/bin/env python3
"""Static checks for the jira-bug-analyzer skill (the skill is prose + shell, so this is its type-check).

Usage:
  python3 scripts/lint_skill.py            # human report, exit 1 on any error
  python3 scripts/lint_skill.py --json     # machine report (used by scripts/metrics.py)
  python3 scripts/lint_skill.py --root DIR # lint another checkout (e.g. a baseline worktree)

Every check is cheap and deterministic. Add a check here whenever a drift bug ships.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys

SKILL_REL = "plugins/jira-bug-analyzer/skills/jira-bug-analyzer"
PLUGIN_JSON_REL = "plugins/jira-bug-analyzer/.claude-plugin/plugin.json"
MARKET_JSON_REL = ".claude-plugin/marketplace.json"
KNOWN_SECRETS_REL = "scripts/lint-known-secrets.txt"

SKILL_MD_MAX_BYTES = 20000
DESCRIPTION_MAX_CHARS = 400
# Human-facing pages may repeat numbers for readability; every other file must point at constants.md.
CONSTANT_COPY_ALLOWED = {"references/constants.md", "usage-by-mode.md", "assets/flow-preview.html"}
REMOVED_FLAGS = ("--pr-window", "--every")
# --pr-window is removed for solo modes but still drives TEAM_PR_ROUND in --team.
REMOVED_FLAG_ALLOWED_IN = {"--pr-window": {"team/team.md", "references/phase1-init-multi-mode-with-team.md"}}
REMOVED_MARKERS = ("removed", "đã bỏ", "warn+ignore", "deprecated", "bỏ qua nếu truyền", "không còn")
SECRET_PATTERNS = [
    re.compile(r"figd_[A-Za-z0-9_-]{20,}"),
    re.compile(r"AIza[0-9A-Za-z_-]{35}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?:TOKEN|KEY|SECRET|PASSWORD)\"\s*:\s*\"(?!\$\{)[A-Za-z0-9+/=_-]{24,}\""),
]
# A script may skip `set -euo pipefail` only when it says why (e.g. "always exits 0" by contract).
STRICT_EXEMPT_MARKER = "lint: no-strict-mode"


class Report:
    def __init__(self):
        self.errors, self.warnings, self.metrics = [], [], {}

    def err(self, check, msg):
        self.errors.append({"check": check, "msg": msg})

    def warn(self, check, msg):
        self.warnings.append({"check": check, "msg": msg})


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def skill_files(skill, exts):
    for d, _, files in os.walk(skill):
        for name in sorted(files):
            if name.endswith(exts):
                yield os.path.join(d, name)


def rel(path, base):
    return os.path.relpath(path, base)


def frontmatter_description(text):
    m = re.search(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return ""
    d = re.search(r'^description:\s*"(.*)"\s*$', m.group(1), re.M) or re.search(r"^description:\s*(.*)$", m.group(1), re.M)
    return d.group(1) if d else ""


def check_tags(skill, md, r):
    defined = set()
    for path in (os.path.join(skill, "SKILL.md"), os.path.join(skill, "references/golden-rules.md")):
        if os.path.exists(path):
            defined |= set(re.findall(r"`\[([A-Z][A-Z0-9-]{2,})\]`", read(path).split("## Mode dispatch")[0] if path.endswith("SKILL.md") else read(path)))
    used = {}
    for path, text in md.items():
        for tag in re.findall(r"`\[([A-Z][A-Z0-9-]{2,})\]`", text):
            used.setdefault(tag, rel(path, skill))
    missing = sorted(t for t in used if t not in defined)
    for t in missing:
        r.err("tag-undefined", f"`[{t}]` used (first in {used[t]}) but not defined in the SKILL.md tag table or golden-rules.md")
    r.metrics["tags_undefined"] = len(missing)


def check_refs(skill, md, r):
    broken = set()
    pat = re.compile(r"(?<![\w/.-])((?:references|assets|team)/[A-Za-z0-9_./-]+\.(?:md|sh|json|html|cjs))")
    for path, text in md.items():
        for ref in pat.findall(text):
            if not os.path.exists(os.path.join(skill, ref)):
                broken.add((ref, rel(path, skill)))
    for ref, where in sorted(broken):
        r.err("ref-broken", f"{where} points at {ref}, which does not exist")
    r.metrics["refs_broken"] = len(broken)


def check_removed_flags(skill, md, r):
    n = 0
    for path, text in md.items():
        p = rel(path, skill)
        for i, line in enumerate(text.splitlines(), 1):
            live = [f for f in REMOVED_FLAGS if f in line and p not in REMOVED_FLAG_ALLOWED_IN.get(f, ())]
            if live and not any(k in line.lower() for k in REMOVED_MARKERS):
                n += 1
                r.err("flag-removed", f"{p}:{i} describes a removed flag ({', '.join(live)}) as if active")
    r.metrics["removed_flag_live_mentions"] = n


def check_constant_copies(skill, files, r):
    consts = os.path.join(skill, "references/constants.md")
    if not os.path.exists(consts):
        r.warn("constants-missing", "references/constants.md does not exist yet")
        r.metrics["constant_copies"] = None
        return
    thr = re.compile(r"(?:≥|>=)\s?(?:40|80|90)\b")
    n = 0
    for path, text in files.items():
        p = rel(path, skill)
        if p in CONSTANT_COPY_ALLOWED:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if thr.search(line) and "constants.md" not in line:
                n += 1
                r.err("constant-copy", f"{p}:{i} repeats an --auto threshold; reference references/constants.md instead")
    r.metrics["constant_copies"] = n


def check_build_cmd(skill, files, r):
    hits = sorted({rel(p, skill) for p, t in files.items() if "assembleAppDevDebug" in t and not p.endswith(("references/constants.md", "assets/init-lib.sh"))})
    for p in hits:
        r.err("build-hardcoded", f"{p} hard-codes assembleAppDevDebug; use <BUILD_CMD> (constants.md DEFAULT_BUILD_CMD)")
    r.metrics["build_cmd_hardcoded_files"] = len(hits)


def check_agent_model(skill, md, r):
    n = 0
    for path, text in md.items():
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if re.search(r"\bAgent\(\{", line):
                window = "\n".join(lines[i:i + 10])
                if not re.search(r"\bmodel\s*:", window):
                    n += 1
                    r.err("agent-no-model", f"{rel(path, skill)}:{i + 1} spawns Agent({{…}}) without a model")
    r.metrics["agent_spawns_without_model"] = n


def check_phase_checklists(skill, md, r):
    """Every phase file opens with a must-do checklist (runs skim files with head/grep), and ledger
    writes are commands (assets/ledger.sh), never prose asking a memory-keeper to do it."""
    missing, prose = 0, 0
    for path, text in md.items():
        p = rel(path, skill)
        if os.path.basename(p).startswith("phase") and os.path.dirname(p) == "references":
            if "## Must-do checklist" not in "\n".join(text.splitlines()[:6]):
                missing += 1
                r.err("checklist", f"{p} must open with '## Must-do checklist' (within its first 6 lines)")
        for i, line in enumerate(text.splitlines(), 1):
            if "memory-keeper" in line and "record_bug_status" in line and "ledger.sh" not in line \
                    and not p.startswith("references/helpers/memory.md"):
                prose += 1
                r.err("ledger-prose", f"{p}:{i} asks memory-keeper to write record_bug_status.md — use assets/ledger.sh")
    r.metrics["phase_files_without_checklist"] = missing
    # phase files are what the main session reads whole on every run: checklist + section index only;
    # the text lives in references/details/ and is read one section at a time (assets/section.sh)
    for path, text in md.items():
        p = rel(path, skill)
        if os.path.basename(p).startswith("phase") and os.path.dirname(p) == "references" and len(text.encode()) > 6000:
            r.err("phase-size", f"{p} is {len(text.encode())} B — keep the checklist + section index (≤ 6000 B), move text to references/details/")
    # Jira at Apero is Server/DC: /rest/api/3 does not exist there (AIP396-475 upload failed on it).
    for path, text in md.items():
        for i, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0] if line.lstrip().startswith(("curl", '"$', "'$", "  ", "\t")) else line
            if "/rest/api/3/" in code:
                r.err("jira-api-v3", f"{rel(path, skill)}:{i} calls /rest/api/3 — jira.apero.vn (Server/DC) only has /rest/api/2")
    r.metrics["ledger_writes_as_prose"] = prose


def check_versions(root, r):
    try:
        pv = json.loads(read(os.path.join(root, PLUGIN_JSON_REL)))["version"]
        mk = json.loads(read(os.path.join(root, MARKET_JSON_REL)))
        mv = next(p["version"] for p in mk["plugins"] if p["name"] == "jira-bug-analyzer")
    except Exception as e:  # noqa: BLE001
        r.err("version", f"cannot read versions: {e}")
        return
    if pv != mv:
        r.err("version", f"plugin.json {pv} != marketplace.json {mv}")
    r.metrics["version"] = pv


def check_size(skill, r):
    text = read(os.path.join(skill, "SKILL.md"))
    size, desc = len(text.encode()), len(frontmatter_description(text))
    r.metrics["skill_md_bytes"], r.metrics["description_chars"] = size, desc
    if size > SKILL_MD_MAX_BYTES:
        r.err("size", f"SKILL.md is {size} bytes (max {SKILL_MD_MAX_BYTES}); move detail into references/")
    if desc > DESCRIPTION_MAX_CHARS:
        r.err("size", f"SKILL.md description is {desc} chars (max {DESCRIPTION_MAX_CHARS}); it loads into every session")
    m = re.search(r"^---\n(.*?)\n---", text, re.S)
    # The main session must NOT be pinned to a smaller model: on the A/B pilot (AAP857-113, --auto) the
    # sonnet-pinned main loop opened a PR after 59 s with no build, no device verify and no Jira finalize;
    # the same skill on opus followed every phase. Cost is cut by pinning SUBAGENTS, not the main loop.
    r.metrics["main_model_pinned"] = bool(m and re.search(r"^model:\s*\S+", m.group(1), re.M))
    if r.metrics["main_model_pinned"]:
        r.err("model", "SKILL.md frontmatter pins `model:`; the main loop must run on the user's model (A/B pilot: sonnet skipped verify)")


def check_shell(root, skill, r):
    scripts = list(skill_files(os.path.join(skill, "assets"), (".sh",))) + list(skill_files(os.path.join(root, "scripts"), (".sh",)))
    no_strict, syntax = 0, 0
    for path in scripts:
        text = read(path)
        res = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
        if res.returncode:
            syntax += 1
            r.err("bash-syntax", f"{rel(path, root)}: {res.stderr.strip()}")
        if "set -euo pipefail" not in text and STRICT_EXEMPT_MARKER not in text:
            no_strict += 1
            r.err("bash-strict", f"{rel(path, root)} has no `set -euo pipefail` (or a `# {STRICT_EXEMPT_MARKER}: <why>` comment)")
        if re.search(r"^\s*nohup\s+claude\s+-p", text, re.M):
            r.err("headless-auto", f"{rel(path, root)} launches `nohup claude -p` (invisible, bypasses review gates)")
    r.metrics["scripts_without_strict_mode"] = no_strict
    r.metrics["scripts_syntax_errors"] = syntax
    if shutil.which("shellcheck"):
        res = subprocess.run(["shellcheck", "-S", "error", *scripts], capture_output=True, text=True)
        n = res.stdout.count("SC")
        r.metrics["shellcheck_errors"] = n
        if res.returncode:
            r.err("shellcheck", f"shellcheck reported {n} error(s):\n{res.stdout.strip()}")
    else:
        r.metrics["shellcheck_errors"] = None
        r.warn("shellcheck", "shellcheck not installed; skipped (CI runs it)")


def check_secrets(root, r):
    known_path = os.path.join(root, KNOWN_SECRETS_REL)
    known = set()
    if os.path.exists(known_path):
        known = {l.split()[0] for l in read(known_path).splitlines() if l.strip() and not l.startswith("#")}
    found, new = 0, 0
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", ".idea", "node_modules")]
        for name in files:
            path = os.path.join(d, name)
            if path.endswith(KNOWN_SECRETS_REL) or not name.endswith((".json", ".md", ".sh", ".py", ".js", ".cjs", ".html", ".yml", ".yaml", ".env")):
                continue
            for i, line in enumerate(read(path).splitlines(), 1):
                for pat in SECRET_PATTERNS:
                    for m in pat.finditer(line):
                        found += 1
                        fp = hashlib.sha256(m.group(0).encode()).hexdigest()[:16]
                        if fp not in known:
                            new += 1
                            r.err("secret", f"{rel(path, root)}:{i} looks like a credential (fingerprint {fp}); move it to an env var")
    r.metrics["secrets_found"], r.metrics["secrets_new"] = found, new
    if found - new:
        r.warn("secret", f"{found - new} known credential(s) still in the repo (tracked in {KNOWN_SECRETS_REL}; S0 deferred)")


def check_discord_in_core(skill, r):
    n = 0
    for path in skill_files(os.path.join(skill, "references"), (".md",)):
        if os.path.basename(path).startswith("phase") and "/discord/" not in path:
            n += sum(1 for line in read(path).splitlines() if "discord" in line.lower())
    r.metrics["discord_lines_in_core_phases"] = n
    gr = os.path.join(skill, "references/golden-rules.md")
    r.metrics["golden_rules_bytes"] = len(read(gr).encode()) if os.path.exists(gr) else None


def check_ab_harness(root, r):
    """scripts/ab is public: no user's absolute home path, and the local-data files stay git-ignored."""
    ab = os.path.join(root, "scripts/ab")
    if not os.path.isdir(ab):
        return
    for dp, dn, fn in os.walk(ab):
        dn[:] = [d for d in dn if d not in ("runs", "tickets")]
        for f in fn:
            if f == "cases.json":
                continue
            t = read(os.path.join(dp, f))
            m = re.search(r"/(?:Users|home)/[a-z][\w.-]+/", t)
            if m:
                r.err("ab-paths", f"{rel(os.path.join(dp, f), root)} carries an absolute home path ({m.group(0)}) — use ~ / $HOME")
    gi = read(os.path.join(ab, ".gitignore")) if os.path.exists(os.path.join(ab, ".gitignore")) else ""
    for need in ("cases.json", "tickets/", "runs/"):
        if need not in gi:
            r.err("ab-gitignore", f"scripts/ab/.gitignore must ignore {need} (internal ticket content / local paths)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    skill = os.path.join(root, SKILL_REL)
    r = Report()
    md = {p: read(p) for p in skill_files(skill, (".md",))}
    allf = {p: read(p) for p in skill_files(skill, (".md", ".sh", ".json", ".html"))}
    r.metrics["skill_total_bytes"] = sum(len(t.encode()) for t in allf.values())
    for fn in (lambda: check_tags(skill, md, r), lambda: check_refs(skill, md, r), lambda: check_removed_flags(skill, md, r),
               lambda: check_constant_copies(skill, allf, r), lambda: check_build_cmd(skill, allf, r),
               lambda: check_agent_model(skill, md, r), lambda: check_phase_checklists(skill, md, r), lambda: check_versions(root, r), lambda: check_size(skill, r),
               lambda: check_shell(root, skill, r), lambda: check_secrets(root, r), lambda: check_discord_in_core(skill, r),
               lambda: check_ab_harness(root, r)):
        fn()
    r.metrics["lint_errors"], r.metrics["lint_warnings"] = len(r.errors), len(r.warnings)
    if a.json:
        print(json.dumps({"metrics": r.metrics, "errors": r.errors, "warnings": r.warnings}, ensure_ascii=False, indent=2))
    else:
        for e in r.errors:
            print(f"ERROR [{e['check']}] {e['msg']}")
        for w in r.warnings:
            print(f"warn  [{w['check']}] {w['msg']}")
        print(f"\n{len(r.errors)} error(s), {len(r.warnings)} warning(s)")
    sys.exit(1 if r.errors else 0)


if __name__ == "__main__":
    main()
