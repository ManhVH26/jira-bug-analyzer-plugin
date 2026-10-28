"""Snapshot a Jira ticket as it was BEFORE anyone started fixing it (read-only against real Jira)."""
import json, os, sys, urllib.request
d = json.load(open(os.path.expanduser("~/.claude.json")))
env = next(s["env"] for n, s in d["mcpServers"].items() if "jira" in n.lower() and s.get("env", {}).get("JIRA_PERSONAL_TOKEN"))
URL, TOK = env["JIRA_URL"].rstrip("/"), env["JIRA_PERSONAL_TOKEN"]
def get(path, raw=False):
    r = urllib.request.Request(URL + path, headers={"Authorization": "Bearer " + TOK})
    b = urllib.request.urlopen(r, timeout=60).read()
    return b if raw else json.loads(b)
out = sys.argv[1]
for key in sys.argv[2:]:
    iss = get(f"/rest/api/2/issue/{key}?expand=changelog,renderedFields")
    hist = sorted(iss["changelog"]["histories"], key=lambda h: h["created"])
    # cut = first moment the ticket left its intake status (claim / resolve) -> everything after is the fix
    cut = next((h["created"] for h in hist for it in h["items"] if it["field"] == "status"), "9999")
    f = iss["fields"]
    orig_status = next((it["fromString"] for h in hist for it in h["items"] if it["field"] == "status"), f["status"]["name"])
    f["comment"]["comments"] = [c for c in f["comment"]["comments"] if c["created"] < cut]
    f["comment"]["total"] = f["comment"]["maxResults"] = len(f["comment"]["comments"])
    f["attachment"] = [a for a in f.get("attachment", []) if a["created"] < cut]
    f["worklog"] = {"startAt": 0, "maxResults": 0, "total": 0, "worklogs": []}
    f["status"] = dict(f["status"], name=orig_status)
    f["resolution"] = None; f["resolutiondate"] = None
    f["labels"] = [l for l in f.get("labels", []) if "auto-fix" not in l]
    iss["changelog"] = {"startAt": 0, "maxResults": 0, "total": 0, "histories": [h for h in hist if h["created"] < cut]}
    iss.pop("renderedFields", None)
    kd = os.path.join(out, key, "attachments"); os.makedirs(kd, exist_ok=True)
    for a in f["attachment"]:
        open(os.path.join(kd, f"{a['id']}_{a['filename']}"), "wb").write(get(a["content"].replace(URL, ""), raw=True))
    json.dump(iss, open(os.path.join(out, key, "issue.json"), "w"), ensure_ascii=False, indent=1)
    print(key, "status:", orig_status, "| cut:", cut[:16], "| comments kept:", len(f["comment"]["comments"]), "| attachments:", len(f["attachment"]), "|", f["summary"][:70])
