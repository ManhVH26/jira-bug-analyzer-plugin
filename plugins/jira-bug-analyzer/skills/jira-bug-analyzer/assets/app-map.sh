#!/usr/bin/env bash
# app-map.sh — what the plugin has learned about ONE app, shared by the whole team (shared memory
# project/<PROJ>/app-map.json; .jira-bug/app-map.json when there is no memory clone).
#
# Learn once, reuse, fix when wrong: every entry carries a `check` (text:<visible text> | id:<view id>) that
# must hold when the entry is replayed or saved; dev.sh never trusts an entry it could not check.
#
#   app-map.sh path   <setup.json>                         -> the file in use
#   app-map.sh show   <setup.json>                         -> app facts, after-FO steps, screens, states (one line each)
#   app-map.sh app    <setup.json> [key=value ...]          -> print app facts / set some (applicationId, launch, …)
#   app-map.sh route  <setup.json> <screen|state>           -> "steps<TAB>check" per hop, home first (exit 1: unknown)
#   app-map.sh set    <setup.json> screen|state <name> '<json steps>' '<check>' [from=home]
#   app-map.sh after-fo <setup.json> ['<json steps>']       -> print / set the app's own steps after First Open
#   app-map.sh publish <setup.json>                          -> push the shared copy (background-safe, idempotent)
#
# A/B (final run): per ticket the analyzer and the verifier each re-learned the way to the screen under test
# (AIP396-475: 9 navigation commands) and looked up the app id again; nothing carried to the next ticket.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:?usage: app-map.sh path/show/app/route/set/after-fo/publish <setup.json> ...}"; SETUP="${2:?setup.json}"; shift 2

FILE="$(python3 - "$SETUP" "$(bash "$SELF_DIR/memory-sync.sh" path 2>/dev/null || true)" <<'PY'
import json, os, sys
setup, mem = sys.argv[1], sys.argv[2]
try: s = json.load(open(setup))
except Exception: s = {}
proj = s.get("project") or s.get("board") or ""
if mem and os.path.isdir(mem) and proj:
    print(os.path.join(mem, "project", proj, "app-map.json"))
else:
    print(os.path.join(os.path.dirname(os.path.abspath(setup)), "app-map.json"))
PY
)"

if [ "$CMD" = path ]; then echo "$FILE"; exit 0; fi
if [ "$CMD" = publish ]; then
  case "$FILE" in */project/*/app-map.json) bash "$SELF_DIR/memory-sync.sh" push "$FILE" "app-map: $(basename "$(dirname "$FILE")")" >/dev/null 2>&1 && echo "MAP_PUBLISHED=$FILE" || echo "MAP_PUBLISH=failed (kept locally: $FILE)" ;;
    *) echo "MAP_PUBLISH=local-only $FILE" ;; esac
  exit 0
fi

python3 - "$CMD" "$FILE" "$@" <<'PY'
import json, os, sys, datetime
cmd, path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try: m = json.load(open(path))
except Exception: m = {}
m.setdefault("app", {}); m.setdefault("afterFirstOpen", []); m.setdefault("screens", {}); m.setdefault("states", {})
def save():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    m["updated"] = datetime.date.today().isoformat()
    json.dump(m, open(path, "w"), ensure_ascii=False, indent=1)
if cmd == "show":
    print("APP " + " ".join(f"{k}={v}" for k, v in m["app"].items()) if m["app"] else "APP (none)")
    print("AFTER_FO " + json.dumps(m["afterFirstOpen"], ensure_ascii=False))
    for kind in ("screens", "states"):
        for n, e in m[kind].items():
            print(f"{kind[:-1].upper()} {n} from={e.get('from') or '-'} check={e.get('check')} steps={len(e.get('steps', []))}")
    if not (m["app"] or m["screens"] or m["states"] or m["afterFirstOpen"]): print("MAP=empty — learn as you go, then save with dev.sh map_save")
elif cmd == "app":
    if args:
        for kv in args:
            k, v = kv.split("=", 1); m["app"][k] = v
        save(); print("MAP_SAVED=app " + " ".join(args))
    else:
        for k, v in m["app"].items(): print(f"{k}={v}")
elif cmd == "after-fo":
    if args:
        m["afterFirstOpen"] = json.loads(args[0]); save(); print("MAP_SAVED=afterFirstOpen")
    else:
        print("\n".join(m["afterFirstOpen"]))
elif cmd == "route":
    name = args[0]; hops = []; seen = set()
    entry = m["screens"].get(name) or m["states"].get(name)
    if entry is None and name != "home": print(f"MAP=unknown {name}"); sys.exit(1)
    while entry is not None and name not in seen:
        seen.add(name); hops.append(entry)
        name = entry.get("from") or "home"
        entry = None if name == "home" and "home" not in m["screens"] else m["screens"].get(name)
    for e in reversed(hops):
        print(json.dumps(e.get("steps", []), ensure_ascii=False) + "\t" + (e.get("check") or ""))
elif cmd == "set":
    kind, name, steps, check = args[0], args[1], json.loads(args[2]), args[3]
    frm = next((a.split("=", 1)[1] for a in args[4:] if a.startswith("from=")), "home")
    if kind not in ("screen", "state") or not check: print("MAP_ERROR=need screen|state and a check"); sys.exit(2)
    m[kind + "s"][name] = {"from": None if name == "home" else frm, "steps": steps, "check": check,
                           "verified": datetime.date.today().isoformat()}
    save(); print(f"MAP_SAVED={kind}:{name}")
else:
    print("MAP_ERROR=unknown command " + cmd); sys.exit(2)
PY
