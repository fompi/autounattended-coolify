#!/usr/bin/env python3
"""Simulador de la API de Cloudflare para las pruebas.

Implementa solo lo que usa setup.sh: verificacion de token, listado y consulta
de zonas, cuentas, tuneles (crear, token, configuracion de ingress) y registros
DNS. Guarda el estado en memoria y lo expone en /__state para que las pruebas
puedan comprobar QUE se creo, no solo que la llamada devolvio 200.

  cf-mock.py PUERTO [--zones N]

El token valido es GOODTOKEN; cualquier otro devuelve 401 como el real.
"""
import base64
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
NZONES = 1
if "--zones" in sys.argv:
    NZONES = int(sys.argv[sys.argv.index("--zones") + 1])

ACCOUNT = {"id": "acct-1", "name": "ferran.fompi@gmail.com's Account"}
ALL_ZONES = [
    {"id": "zone-aaa", "name": "fompi.net", "status": "active", "account": ACCOUNT},
    {"id": "zone-bbb", "name": "otro.com", "status": "active", "account": ACCOUNT},
    {"id": "zone-ccc", "name": "tercero.org", "status": "pending", "account": ACCOUNT},
]
ZONES = ALL_ZONES[:NZONES]
STATE = {"tunnels": {}, "dns": {}, "ingress": None, "log": []}


def tunnel_token(account_id, tunnel_id):
    secret = base64.b64encode(b"0" * 32).decode()
    payload = {"a": account_id, "t": tunnel_id, "s": secret}
    return base64.b64encode(json.dumps(payload).encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        # Una sola lectura: el stream se consume y una segunda llamada
        # bloquearia hasta que el cliente agote su timeout.
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}") if length else {}

    def _ok(self, result, **extra):
        self._send({"success": True, "result": result, "errors": [], **extra})

    def _route(self, method):
        path = self.path

        if path == "/__state":
            return self._send({"success": True, "result": STATE, "errors": []})

        if self.headers.get("Authorization", "") != "Bearer GOODTOKEN":
            return self._send({
                "success": False, "result": None,
                "errors": [{"code": 1000, "message": "Invalid API Token"}],
            }, 401)

        STATE["log"].append(f"{method} {path}")

        if path.startswith("/user/tokens/verify"):
            return self._ok({"status": "active"})

        m = re.match(r"^/accounts/([^/]+)/cfd_tunnel/([^/]+)/configurations$", path)
        if m and method == "PUT":
            body = self._read_body()
            STATE["ingress"] = body.get("config", {}).get("ingress")
            return self._ok({"config": body})

        m = re.match(r"^/accounts/([^/]+)/cfd_tunnel/([^/]+)/token$", path)
        if m:
            return self._ok(tunnel_token(m.group(1), m.group(2)))

        m = re.match(r"^/accounts/([^/]+)/cfd_tunnel", path)
        if m:
            if method == "POST":
                body = self._read_body()
                tid = str(uuid.uuid4())
                STATE["tunnels"][tid] = body.get("name")
                return self._ok({"id": tid, "name": body.get("name"),
                                 "token": tunnel_token(m.group(1), tid)})
            wanted = re.search(r"name=([^&]+)", path)
            found = [{"id": k, "name": v} for k, v in STATE["tunnels"].items()
                     if wanted and v == wanted.group(1)]
            return self._ok(found, result_info={"count": len(found)})

        m = re.match(r"^/zones/([^/]+)/dns_records/([^/?]+)$", path)
        if m and method == "PUT":
            body = self._read_body()
            STATE["dns"][body.get("name")] = body
            return self._ok(body)

        if re.match(r"^/zones/[^/]+/dns_records", path):
            if method == "POST":
                body = self._read_body()
                STATE["dns"][body.get("name")] = body
                return self._ok({**body, "id": str(uuid.uuid4())})
            wanted = re.search(r"name=([^&]+)", path)
            hits = []
            if wanted:
                for name, rec in STATE["dns"].items():
                    if name == wanted.group(1) or f"{name}.fompi.net" == wanted.group(1):
                        hits.append({**rec, "id": "rec-" + name.replace("*", "w")})
            return self._ok(hits, result_info={"count": len(hits)})

        if re.match(r"^/zones/[^/?]+$", path):
            zid = path.rsplit("/", 1)[1]
            hit = [z for z in ZONES if z["id"] == zid]
            return self._ok(hit[0] if hit else None)

        if path.startswith("/accounts/"):
            return self._ok(ACCOUNT)
        if path.startswith("/accounts"):
            return self._ok([ACCOUNT], result_info={"count": 1})

        if path.startswith("/zones"):
            wanted = re.search(r"name=([^&]+)", path)
            hits = [z for z in ZONES if z["name"] == wanted.group(1)] if wanted else ZONES
            return self._ok(hits, result_info={"count": len(hits)})

        return self._send({"success": False,
                           "errors": [{"message": "sin ruta: " + path}]}, 404)

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
