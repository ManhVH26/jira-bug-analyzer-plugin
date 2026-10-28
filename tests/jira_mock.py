"""Tiny Jira Server stand-in for tests/run_all.sh: records every call, answers like REST v2."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
state = {"status": "In Progress", "worklogs": 0, "comments": {}, "attachments": [], "labels": ["old"]}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def note(self, data=b""):
        with open(LOG, "a") as f: f.write(f"{self.command} {self.path} {data[:400]!r}\n")
    def do_GET(self):
        self.note(); p = self.path
        if p.endswith("/transitions"):
            to = "Resolved" if state["status"] == "In Progress" else "In Progress"
            return self.send(200, {"transitions": [{"id": "21" if to == "Resolved" else "11", "to": {"name": to}}]})
        if "fields=labels" in p: return self.send(200, {"fields": {"labels": state["labels"]}})
        if "fields=status" in p: return self.send(200, {"fields": {"status": {"name": state["status"]}}})
        if p.endswith("/worklog"): return self.send(200, {"total": state["worklogs"]})
        if "/comment/" in p:
            cid = p.split("/comment/")[1].split("?")[0]; body = state["comments"][cid]
            html = re.sub(r"!([^!\s]+)!", r'<img src="/secure/attachment/1/\1">', body)
            return self.send(200, {"id": cid, "body": body, "renderedBody": html})
        if p.endswith("/myself"): return self.send(200, {"name": "dev1"})
        self.send(404, {})
    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0))); self.note(data); p = self.path
        if p.endswith("/attachments"):
            name = re.search(rb'filename="([^"]+)"', data).group(1).decode()
            if name in state["attachments"]: name = name.replace(".", "_1.", 1)
            state["attachments"].append(name); return self.send(200, [{"filename": name}])
        if p.endswith("/comment"):
            cid = str(100 + len(state["comments"])); state["comments"][cid] = json.loads(data)["body"]
            return self.send(201, {"id": cid})
        if p.endswith("/transitions"):
            tid = json.loads(data)["transition"]["id"]
            state["status"] = "Resolved" if tid == "21" else "In Progress"; return self.send(204)
        if p.endswith("/worklog"): state["worklogs"] += 1; return self.send(201, {"id": "9" + str(state["worklogs"])})
        self.send(404, {})
    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0))); self.note(data)
        for op in (json.loads(data or b"{}").get("update") or {}).get("labels", []):
            if "add" in op and op["add"] not in state["labels"]: state["labels"].append(op["add"])
        self.send(204)

srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
