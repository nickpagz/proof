#!/usr/bin/env python3
"""A stand-in for CloudUp's API, its S3 upload target and WordPress.com's media endpoints, so the
sharing code can be tested end to end without real accounts. It checks each request the way the
real service would care about and records what happened at GET /log.

    python3 Scripts/mock-share-server.py 8765 &
    PROOF_CLOUDUP_API=http://127.0.0.1:8765/1 PROOF_CLOUDUP_USER=tester PROOF_CLOUDUP_PASSWORD=secret \\
        build/Proof.app/Contents/MacOS/Proof --share image.png --to cloudup --delete-after
    PROOF_WPCOM_API=http://127.0.0.1:8765 PROOF_WPCOM_TOKEN=wptoken PROOF_WPCOM_SITE=123 \\
        build/Proof.app/Contents/MacOS/Proof --share image.png --to wordpress --delete-after

Scripts/test-sharing.sh runs both and checks the log.
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
BASE = f"http://127.0.0.1:{PORT}"
CLOUDUP_AUTH = "Basic " + base64.b64encode(b"tester:secret").decode()
WP_AUTH = "Bearer wptoken"
LOG = []
STATE = {"streams": set(), "items": {}, "s3": {}, "media": {}}


def parse_multipart(body, content_type):
    """Returns [(name, filename, data)] in order."""
    boundary = content_type.split("boundary=", 1)[1].encode()
    parts = []
    for chunk in body.split(b"--" + boundary):
        if not chunk.strip() or chunk.strip() == b"--":
            continue
        chunk = chunk[2:] if chunk.startswith(b"\r\n") else chunk
        header, _, data = chunk.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        disposition = header.decode(errors="replace")
        name = disposition.split('name="', 1)[1].split('"', 1)[0]
        filename = disposition.split('filename="', 1)[1].split('"', 1)[0] if 'filename="' in disposition else None
        parts.append((name, filename, data))
    return parts


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def reply(self, status, obj=None):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def fail(self, status, message):
        LOG.append({"error": message, "path": self.path})
        self.reply(status, {"message": message})

    def do_GET(self):
        if self.path == "/log":
            return self.reply(200, LOG)
        if self.path == "/1/user":
            if self.headers.get("Authorization") != CLOUDUP_AUTH:
                return self.fail(401, "bad credentials")
            LOG.append({"event": "cloudup.user"})
            return self.reply(200, {"username": "tester", "name": "Test Person"})
        self.fail(404, "no route")

    def do_POST(self):
        body = self.body()
        ctype = self.headers.get("Content-Type", "")
        # CloudUp
        if self.path.startswith("/1/"):
            if self.headers.get("Authorization") != CLOUDUP_AUTH:
                return self.fail(401, "bad credentials")
            obj = json.loads(body or b"{}")
            if self.path == "/1/streams":
                sid = f"cStream{len(STATE['streams']) + 1}"
                STATE["streams"].add(sid)
                LOG.append({"event": "cloudup.stream", "title": obj.get("title")})
                return self.reply(201, {"id": sid, "url": f"https://cloudup.com/{sid}"})
            if self.path == "/1/items":
                if self.headers.get("X-Cloudup-Required-Fields") != "1":
                    return self.fail(400, "missing X-Cloudup-Required-Fields")
                for field in ("filename", "mime", "size", "stream_id", "bucket"):
                    if field not in obj:
                        return self.fail(400, f"item missing {field}")
                if obj["stream_id"] not in STATE["streams"]:
                    return self.fail(400, "unknown stream")
                iid = f"iItem{len(STATE['items']) + 1}"
                key = f"{iid}.png"
                STATE["items"][iid] = {"stream": obj["stream_id"], "key": key, "size": obj["size"], "complete": False}
                LOG.append({"event": "cloudup.item", "filename": obj["filename"], "size": obj["size"], "mime": obj["mime"]})
                return self.reply(201, {
                    "id": iid, "url": f"https://cloudup.com/{iid}", "direct_url": f"https://cldup.com/{key}",
                    "s3_url": f"{BASE}/s3", "s3_key": key, "s3_access_key": "AKIATEST",
                    "s3_policy": "cG9saWN5", "s3_signature": "c2lnbmF0dXJl",
                    "s3_required_form_fields": {"success_action_status": "201"},
                })
            return self.fail(404, "no route")
        # S3 form upload
        if self.path == "/s3":
            parts = parse_multipart(body, ctype)
            names = [p[0] for p in parts]
            if names[-1] != "file":
                return self.fail(400, "file must be the last field")
            fields = {p[0]: p[2].decode(errors="replace") for p in parts if p[0] != "file"}
            for field in ("key", "AWSAccessKeyId", "acl", "policy", "signature", "success_action_status", "Content-Type"):
                if field not in fields:
                    return self.fail(400, f"s3 form missing {field}")
            item = next((i for i in STATE["items"].values() if i["key"] == fields["key"]), None)
            if item is None:
                return self.fail(403, "unknown key")
            data = parts[-1][2]
            if len(data) != item["size"] or str(len(data)) != fields.get("Content-Length"):
                return self.fail(400, f"size mismatch: got {len(data)}, item says {item['size']}")
            STATE["s3"][fields["key"]] = data
            LOG.append({"event": "s3.upload", "key": fields["key"], "bytes": len(data), "png": data[:8] == b"\x89PNG\r\n\x1a\n"})
            return self.reply(201)
        # WordPress.com
        if self.path.startswith("/rest/v1.1/sites/"):
            if self.headers.get("Authorization") != WP_AUTH:
                return self.reply(403, {"error": "unauthorized", "message": "bad token"})
            segments = self.path.split("/")
            site = segments[4]
            if self.path.endswith("/media/new"):
                parts = parse_multipart(body, ctype)
                files = [p for p in parts if p[0] == "media[]"]
                titles = [p[2].decode() for p in parts if p[0] == "attrs[0][title]"]
                if not files:
                    return self.fail(400, "no media[]")
                mid = 70 + len(STATE["media"]) + 1
                STATE["media"][mid] = site
                LOG.append({"event": "wp.upload", "site": site, "filename": files[0][1], "bytes": len(files[0][2]), "title": titles[0] if titles else None})
                return self.reply(200, {"media": [{"ID": mid, "URL": f"https://example.files.wordpress.com/2026/11/{files[0][1]}"}]})
            if self.path.endswith("/delete"):
                mid = int(segments[6])
                if STATE["media"].pop(mid, None) is None:
                    return self.fail(404, "no such media")
                LOG.append({"event": "wp.delete", "media": mid})
                return self.reply(200, {"ID": mid, "status": "deleted"})
        self.fail(404, "no route")

    def do_PATCH(self):
        body = self.body()
        if self.headers.get("Authorization") != CLOUDUP_AUTH:
            return self.fail(401, "bad credentials")
        iid = self.path.rsplit("/", 1)[-1]
        item = STATE["items"].get(iid)
        if item is None:
            return self.fail(404, "no such item")
        if json.loads(body or b"{}").get("complete") is not True:
            return self.fail(400, "expected complete: true")
        if item["key"] not in STATE["s3"]:
            return self.fail(400, "completed before the file arrived")
        item["complete"] = True
        LOG.append({"event": "cloudup.complete", "item": iid})
        return self.reply(200, {"id": iid, "url": f"https://cloudup.com/{iid}", "direct_url": f"https://cldup.com/{item['key']}"})

    def do_DELETE(self):
        if self.headers.get("Authorization") != CLOUDUP_AUTH:
            return self.fail(401, "bad credentials")
        sid = self.path.rsplit("/", 1)[-1]
        if sid not in STATE["streams"]:
            return self.fail(404, "no such stream")
        STATE["streams"].discard(sid)
        LOG.append({"event": "cloudup.delete", "stream": sid})
        return self.reply(204)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
