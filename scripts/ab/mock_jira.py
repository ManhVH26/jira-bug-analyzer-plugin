"""Jira Server stand-in for the A/B runs: serves pre-fix ticket snapshots, applies writes in memory,
logs every request as JSONL (the scorer reads it). Usage: mock_jira.py <tickets-dir> <port-file> <log.jsonl>"""
import copy, datetime, json, os, re, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TICKETS, PORTF, LOG = sys.argv[1:4]
ME = {"name": "sandbox-dev", "key": "sandbox-dev", "displayName": "Sandbox Dev", "emailAddress": "dev@sandbox", "active": True, "timeZone": "Asia/Ho_Chi_Minh"}
ISSUES, FILES = {}, {}
for k in os.listdir(TICKETS):
    p = os.path.join(TICKETS, k, "issue.json")
    if os.path.exists(p):
        ISSUES[k] = json.load(open(p))
        ad = os.path.join(TICKETS, k, "attachments")
        for fn in os.listdir(ad) if os.path.isdir(ad) else []:
            aid, name = fn.split("_", 1); FILES[aid] = os.path.join(ad, fn)
STATUSES = {"Request": "1", "In Progress": "3", "Resolved": "5", "Closed": "6", "Reopened": "4"}
NEXT_ID = [900000]

def now(): return datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S.000%z")
def nid(): NEXT_ID[0] += 1; return str(NEXT_ID[0])
def status_obj(name): return {"name": name, "id": STATUSES.get(name, "1"), "statusCategory": {"key": "done" if name in ("Resolved", "Closed") else "indeterminate" if name == "In Progress" else "new"}}
def transitions(cur):
    t = {"Request": [("11", "In Progress"), ("41", "Resolved"), ("51", "Closed")],
         "In Progress": [("21", "Resolved"), ("31", "Request"), ("61", "Closed")],
         "Resolved": [("71", "Reopened"), ("81", "Closed")], "Reopened": [("11", "In Progress"), ("41", "Resolved")]}.get(cur, [])
    return [{"id": i, "name": f"To {n}", "to": status_obj(n), "fields": {}} for i, n in t]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def out(self, code, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj, ensure_ascii=False).encode())
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        with open(LOG, "a") as f:
            f.write(json.dumps({"t": now(), "m": self.command, "p": self.path, "code": code, "body": self._body[:2000]}, ensure_ascii=False) + "\n")
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); b = self.rfile.read(n) if n else b""
        self._body = b.decode("utf-8", "replace") if not b.startswith(b"--") else "<multipart %d bytes>" % len(b)
        return b
    def key_of(self, path):
        m = re.search(r"/issue/([A-Z][A-Z0-9]+-\d+)", path); return m.group(1) if m else None
    def issue(self, key, q):
        i = copy.deepcopy(ISSUES[key]); f = i["fields"]
        if "fields" in q and q["fields"][0] not in ("*all", "*navigable"):
            want = set(q["fields"][0].split(",")); i["fields"] = {k: v for k, v in f.items() if k in want or k in ("summary", "status")}
        return i
    def do_GET(self):
        self._body = ""; u = urllib.parse.urlparse(self.path); p, q = u.path, urllib.parse.parse_qs(u.query); key = self.key_of(p)
        if p.endswith("/myself"): return self.out(200, ME)
        if p.endswith("/serverInfo"): return self.out(200, {"version": "9.12.0", "deploymentType": "Server", "baseUrl": "http://jira.sandbox"})
        if p.endswith("/field"): return self.out(200, [{"id": "summary", "name": "Summary", "custom": False}, {"id": "labels", "name": "Labels", "custom": False}])
        if "/secure/attachment/" in p or "/attachment/content/" in p:
            aid = re.search(r"/(\d+)", p.split("attachment", 1)[1]).group(1)
            return self.out(200, raw=open(FILES[aid], "rb").read(), ctype="application/octet-stream") if aid in FILES else self.out(404, {})
        if p.endswith("/search") or p.endswith("/search/jql"):
            jql = (q.get("jql") or [""])[0]
            hits = [self.issue(k, q) for k in ISSUES if k in jql or k.split("-")[0] in jql]
            return self.out(200, {"startAt": 0, "maxResults": 50, "total": len(hits), "issues": hits})
        if key and key in ISSUES:
            f = ISSUES[key]["fields"]
            if p.endswith("/transitions"): return self.out(200, {"transitions": transitions(f["status"]["name"])})
            if p.endswith("/comment"): return self.out(200, f["comment"])
            m = re.search(r"/comment/(\d+)", p)
            if m:
                c = next((c for c in f["comment"]["comments"] if c["id"] == m.group(1)), None)
                if not c: return self.out(404, {})
                html = re.sub(r"!([^!|\s]+)(\|[^!]*)?!", r'<img src="/secure/attachment/0/\1">', c["body"])
                return self.out(200, dict(c, renderedBody=html))
            if p.endswith("/worklog"): return self.out(200, f["worklog"])
            if p.endswith("/remotelink") or p.endswith("/watchers") or p.endswith("/votes"): return self.out(200, [])
            if p.endswith("/editmeta"): return self.out(200, {"fields": {}})
            return self.out(200, self.issue(key, q))
        if key: return self.out(404, {"errorMessages": [f"Issue {key} does not exist"]})
        return self.out(200, {})
    def write(self):
        b = self.body(); u = urllib.parse.urlparse(self.path); p = u.path; key = self.key_of(p)
        if not key or key not in ISSUES: return self.out(404, {"errorMessages": ["no such issue"]})
        f = ISSUES[key]["fields"]
        if p.endswith("/attachments"):
            out = []
            for m in re.finditer(rb'filename="([^"]+)"', b):
                name = m.group(1).decode(); names = {a["filename"] for a in f["attachment"]}
                base, ext = os.path.splitext(name); n = 1
                while name in names: name = f"{base}_{n}{ext}"; n += 1
                aid = nid(); a = {"id": aid, "filename": name, "created": now(), "author": ME, "content": f"/secure/attachment/{aid}/{name}", "mimeType": "image/png"}
                f["attachment"].append(a); out.append(a)
            return self.out(200, out)
        data = json.loads(b or b"{}")
        if p.endswith("/transitions"):
            tid = data.get("transition", {}).get("id"); t = next((t for t in transitions(f["status"]["name"]) if t["id"] == str(tid)), None)
            if not t: return self.out(400, {"errorMessages": [f"transition {tid} not valid from {f['status']['name']}"]})
            f["status"] = status_obj(t["to"]["name"]); a = (data.get("fields") or {}).get("assignee")
            if a: f["assignee"] = ME
            return self.out(204)
        if p.endswith("/comment"):
            c = {"id": nid(), "body": data.get("body", ""), "author": ME, "created": now(), "updated": now()}
            f["comment"]["comments"].append(c); f["comment"]["total"] += 1; return self.out(201, c)
        m = re.search(r"/comment/(\d+)", p)
        if m:
            c = next((c for c in f["comment"]["comments"] if c["id"] == m.group(1)), None)
            if c: c["body"] = data.get("body", c["body"]); return self.out(200, c)
            return self.out(404, {})
        if p.endswith("/worklog"):
            w = {"id": nid(), "timeSpent": data.get("timeSpent"), "comment": data.get("comment", ""), "author": ME, "started": now()}
            f["worklog"]["worklogs"].append(w); f["worklog"]["total"] += 1; return self.out(201, w)
        if p.endswith("/assignee"): f["assignee"] = ME; return self.out(204)
        if p.endswith("/remotelink"): return self.out(201, {"id": nid()})
        if p.endswith("/watchers"): return self.out(204)
        upd = data.get("fields") or {}
        for op in (data.get("update") or {}).get("labels", []):
            if "add" in op: f["labels"] = sorted(set(f.get("labels", [])) | {op["add"]})
        f.update({k: v for k, v in upd.items() if k in ("labels", "summary", "description")})
        return self.out(204)
    do_POST = do_PUT = write
    def do_DELETE(self): self._body = ""; self.out(204)

for _i in ISSUES.values(): _i["fields"]["status"] = status_obj(_i["fields"]["status"]["name"])
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTF, "w").write(str(srv.server_address[1]))
srv.serve_forever()
