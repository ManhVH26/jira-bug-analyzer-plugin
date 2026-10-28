"""Score A/B runs. Usage: ab_report.py <runs-dir> [--json out.json]   (ground truth from cases.json next to this file)
Per run: outcome, correctness vs the real fix, required steps, cost, time."""
import glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = json.load(open(os.path.join(HERE, "cases.json")))
FIX = {k: (os.path.expanduser(v["repo"]), v["fix"]) for k, v in CASES.items() if not k.startswith("_")}  # ground truth per ticket

def sh(*a, cwd=None):
    r = subprocess.run(a, cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip()

def events(path):
    out = []
    for l in open(path, encoding="utf-8", errors="replace"):
        try: out.append(json.loads(l))
        except ValueError: pass
    return out

def tool_uses(evs):
    # transcripts log the same tool_use more than once (stream.jsonl also relays subagent events,
    # and a message can be written once per content block) -> count each tool_use id once
    seen = set()
    for d in evs:
        m = d.get("message")
        if not isinstance(m, dict) or not isinstance(m.get("content"), list):
            continue   # some stream events carry a plain-string message
        for b in m["content"]:
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") not in seen:
                seen.add(b.get("id")); yield b

def images_read(evs):
    seen = set(); n = 0
    for d in evs:
        m = d.get("message")
        if not isinstance(m, dict) or not isinstance(m.get("content"), list):
            continue
        for b in m["content"]:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") not in seen and isinstance(b.get("content"), list):
                if any(isinstance(x, dict) and x.get("type") == "image" for x in b["content"]):
                    seen.add(b.get("tool_use_id")); n += 1
    return n

def score(run):
    T = open(os.path.join(run, "ticket")).read().strip(); V = open(os.path.join(run, "version")).read().strip()
    P = open(os.path.join(run, "project")).read().strip(); BR = open(os.path.join(run, "branch")).read().strip()
    r = {"ticket": T, "version": V}
    t = json.load(open(os.path.join(run, "timing.json"))) if os.path.exists(os.path.join(run, "timing.json")) else {}
    r["minutes"] = round(t.get("seconds", 0) / 60, 1)
    main = events(os.path.join(run, "stream.jsonl"))
    res = next((d for d in main if d.get("type") == "result"), {})
    r["cost_usd"] = round(res.get("total_cost_usd") or 0, 2)
    r["turns"] = res.get("num_turns")
    mu = res.get("modelUsage") or {}
    r["models"] = {k.replace("claude-", ""): {"out": v.get("outputTokens", 0), "cache_read": v.get("cacheReadInputTokens", 0), "usd": round(v.get("costUSD", 0), 2)} for k, v in mu.items()}
    init = next((d for d in main if d.get("type") == "system" and d.get("subtype") == "init"), {})
    r["main_model"] = (init.get("model") or "").replace("claude-", "")
    # all transcripts: main + subagents (claude writes them under HOME/.claude/projects)
    subs = glob.glob(os.path.join(run, "home/.claude/projects/*/*/subagents/*.jsonl"))
    allev = main + [e for s in subs for e in events(s)]
    uses = list(tool_uses(allev))
    cmds = [u["input"].get("command", "") for u in uses if u["name"] == "Bash"]
    r["tool_calls"] = len(uses); r["subagents"] = len(subs); r["images_read"] = images_read(allev)
    agents = [u["input"] for u in tool_uses(main) if u["name"] in ("Agent", "Task")]
    r["agent_models"] = sorted({(a.get("model") or "inherit") for a in agents})
    # verifier effort = tool calls inside subagents whose description mentions verify
    ver = 0
    for s in subs:
        meta = s[:-6] + ".meta.json"
        desc = json.load(open(meta)).get("description", "") if os.path.exists(meta) else ""
        if re.search(r"verif", desc, re.I): ver += len(list(tool_uses(events(s))))
    r["verifier_calls"] = ver
    # --- required steps
    jira = events(os.path.join(run, "jira.jsonl")) if os.path.exists(os.path.join(run, "jira.jsonl")) else []
    w = [j for j in jira if j["m"] in ("POST", "PUT") and T in j["p"]]
    def trans_to(tid_set): return [j for j in w if j["p"].endswith("/transitions") and re.search(r'"id":\s*"?(%s)"?' % "|".join(tid_set), j["body"])]
    claim = trans_to(["11"]); resolve = trans_to(["21", "41"])
    first_edit = next((i for i, u in enumerate(uses) if u["name"] in ("Edit", "Write") and P in u["input"].get("file_path", "") and ".jira-bug" not in u["input"].get("file_path", "")), None)
    r["claimed"] = bool(claim)
    att = [j for j in w if j["p"].endswith("/attachments")]
    comments = [j for j in w if j["p"].endswith("/comment")]
    embedded = any(re.search(r"![^!\s]+\.(png|jpe?g|gif|webp)(\|[^!]*)?!", c["body"]) for c in comments)
    r["jira_evidence_embedded"] = bool(att) and embedded
    r["jira_resolved"] = bool(resolve)
    r["jira_worklog"] = any(j["p"].endswith("/worklog") for j in w)
    mem = os.path.join(run, "memory.git")
    log = sh("git", "--git-dir", mem, "log", "--format=%s", "master")
    r["ledger"] = sorted(set(re.findall(r"ledger %s (\S+)" % re.escape(T), log))) or (["(other write)"] if T in sh("git", "--git-dir", mem, "log", "-p", "-3", "master") else [])
    pw = os.path.join(P, ".jira-bug/pr-watch.json")
    r["pr_watch"] = os.path.exists(pw) and bool(json.load(open(pw)))
    gh = open(os.path.join(run, "gh.log")).read() if os.path.exists(os.path.join(run, "gh.log")) else ""
    r["pr_created"] = "pr create" in gh
    lockuse = sum(1 for c in cmds if "device-lock.sh" in c)
    bare = sum(1 for c in cmds if re.search(r"(^|[;&|(\s])adb\s", c) and "device-lock.sh" not in c and not re.search(r"adb devices|adb -s \S+ get-state$", c))
    r["device_lock_calls"], r["bare_adb_calls"] = lockuse, bare
    # from the subagent records, not only the stream: a stream can be partial (see stream_partial)
    metas = [json.load(open(x[:-6] + ".meta.json")).get("description", "") for x in subs if os.path.exists(x[:-6] + ".meta.json")]
    r["code_review"] = any(re.search(r"review", (a.get("description", "") + a.get("subagent_type", "")), re.I) for a in agents) \
        or any(re.search(r"review", d, re.I) for d in metas)
    # the stream's result covers only the last session when a run restarted (or the harness re-ran the
    # launch line): its cost/duration are then partial — flag it instead of reporting them as the run's
    # (several result events are normal — one per turn, total_cost_usd is cumulative; a SECOND main session is not)
    r["stream_partial"] = len(glob.glob(os.path.join(run, "home/.claude/projects/*/*.jsonl"))) > 1
    allres = [d for d in main if d.get("type") == "result"]
    if allres: r["cost_usd"] = round(max(x.get("total_cost_usd") or 0 for x in allres), 2)
    r["build_cmds"] = sorted({m for c in cmds for m in re.findall(r"gradlew\s+(?:-\S+\s+)*([:\w]*assemble\w+)", c)})
    # --- correctness vs the real fix
    repo, sha = FIX[T]
    real = set(sh("git", "-C", repo, "show", "--name-only", "--format=", sha).split())
    branches = [b for b in sh("git", "--git-dir", os.path.join(run, "remote.git"), "for-each-ref", "--format=%(refname:short)", "refs/heads").split() if b != BR]
    got = set()
    for b in branches:
        got |= set(sh("git", "--git-dir", os.path.join(run, "remote.git"), "diff", "--name-only", BR, b).split())
    if not got:  # not pushed: look at the worktree/branch in the local clone
        for b in sh("git", "-C", P, "for-each-ref", "--format=%(refname:short)", "refs/heads").split():
            if b != BR: got |= set(sh("git", "-C", P, "diff", "--name-only", BR, b).split())
    # also count work left in worktrees (committed on a branch or still uncommitted)
    for blk in sh("git", "-C", P, "worktree", "list", "--porcelain").split(chr(10) * 2):
        wt = blk.split(chr(10))[0].replace("worktree ", "")
        if not wt or os.path.realpath(wt) == os.path.realpath(P): continue
        got |= set(sh("git", "-C", wt, "diff", "--name-only", BR).split())
        got |= set(sh("git", "-C", wt, "ls-files", "--others", "--exclude-standard").split())
    got = {g for g in got if not g.startswith(".jira-bug")}
    r["files_real"], r["files_got"] = len(real), len(got)
    r["file_overlap"] = round(len(real & got) / len(real | got), 2) if (real | got) else None
    r["deferred"] = (any("deferred" in l for l in r["ledger"]) or bool(re.search(r"defer|hoãn", " ".join(c["body"] for c in comments), re.I))) and not r["pr_created"]
    # sandbox leak: any tool call that touched the real shared memory / transcripts / skills outside this run
    real = open(os.path.join(run, "real_home")).read().strip() if os.path.exists(os.path.join(run, "real_home")) else os.path.expanduser("~")
    # (a real clone may live anywhere under the real HOME, e.g. ~/StudioProjects/jira-bug-memory — an A/B
    #  analyzer found one there and read a KB entry written from the very fix under test)
    pat = re.compile(re.escape(real) + r"/(?:[^\s\"']*/)?(?:\.claude/(?:projects|skills)|jira-bug-memory)")
    here = {run, os.path.abspath(run), os.path.realpath(run)}   # the run's own files are not a leak, however spelled
    def own(s):
        for h in sorted(here, key=len, reverse=True): s = s.replace(h, "<RUN>")
        return s
    leaks = [m.group(0) for u in uses for m in [pat.search(own(json.dumps(u["input"])))] if m]
    r["leaks"] = len(leaks); r["leak_examples"] = leaks[:3]
    r["final_text"] = (res.get("result") or "")[:400]
    return r

if __name__ == "__main__":
    runs = sorted(d for d in glob.glob(os.path.join(sys.argv[1], "*-*-*")) if os.path.exists(os.path.join(d, "stream.jsonl")))
    rows = [score(d) for d in runs]
    if "--json" in sys.argv: json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)
    keys = ["ticket", "version", "minutes", "cost_usd", "main_model", "tool_calls", "verifier_calls", "claimed", "ledger", "pr_created", "pr_watch",
            "images_read", "jira_evidence_embedded", "jira_resolved", "jira_worklog", "device_lock_calls", "bare_adb_calls", "code_review", "build_cmds", "file_overlap", "deferred", "leaks", "stream_partial"]
    for r in rows:
        print(" | ".join(f"{k}={r.get(k)}" for k in keys))
