#!/usr/bin/env python3
"""Simulador de la API de Cloudflare para las pruebas.

Implementa solo lo que usa setup.sh: verificacion de token, listado y consulta
de zonas, cuentas, tuneles (crear, token, configuracion de ingress) y registros
DNS. Guarda el estado en memoria y lo expone en /__state para que las pruebas
puedan comprobar QUE se creo, no solo que la llamada devolvio 200.

  cf-mock.py PUERTO [--zones N] [--tunnel-status MODO]

El token valido es GOODTOKEN; cualquier otro devuelve 401 como el real.

--tunnel-status controla lo que responde GET /accounts/{a}/cfd_tunnel/{id},
que es como setup.sh comprueba que el tunel esta CONECTADO de verdad (#6):

  healthy      (por defecto) conectado
  degraded     conectado, con menos conexiones al edge de las esperadas
  inactive     nunca conecta: sirve para probar que el paso falla con tiempo
               maximo corto en vez de dar un falso positivo
  flaky:N      'inactive' las primeras N consultas y 'healthy' despues: sirve
               para probar que hay reintentos de verdad y no un unico sondeo
               con suerte

El numero de consultas de estado se expone en /__state como status_queries.
"""
import base64
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
NZONES = 1
if "--zones" in sys.argv:
    NZONES = int(sys.argv[sys.argv.index("--zones") + 1])
TUNNEL_STATUS = "healthy"
if "--tunnel-status" in sys.argv:
    TUNNEL_STATUS = sys.argv[sys.argv.index("--tunnel-status") + 1]

ACCOUNT = {"id": "acct-1", "name": "ferran.fompi@gmail.com's Account"}
ALL_ZONES = [
    {"id": "zone-aaa", "name": "fompi.net", "status": "active", "account": ACCOUNT},
    {"id": "zone-bbb", "name": "otro.com", "status": "active", "account": ACCOUNT},
    {"id": "zone-ccc", "name": "tercero.org", "status": "pending", "account": ACCOUNT},
]
ZONES = ALL_ZONES[:NZONES]
STATE = {"tunnels": {}, "dns": {}, "ingress": None, "log": [], "status_queries": 0}


def tunnel_status():
    """Estado del tunel, contando las consultas para poder comprobar reintentos."""
    STATE["status_queries"] += 1
    if TUNNEL_STATUS.startswith("flaky:"):
        fallos = int(TUNNEL_STATUS.split(":", 1)[1])
        return "inactive" if STATE["status_queries"] <= fallos else "healthy"
    return TUNNEL_STATUS


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

        # Ojo con el orden: esta ruta tiene que ir despues de /token y de
        # /configurations (que tambien empiezan por el id) y antes del prefijo
        # generico de cfd_tunnel, o no se alcanzaria nunca.
        m = re.match(r"^/accounts/([^/]+)/cfd_tunnel/([^/?]+)$", path)
        if m and method == "GET":
            tid = m.group(2)
            if tid not in STATE["tunnels"]:
                return self._send({"success": False, "result": None, "errors": [
                    {"code": 1003, "message": "tunnel not found"}]}, 404)
            return self._ok({"id": tid, "name": STATE["tunnels"][tid],
                             "status": tunnel_status()})

        m = re.match(r"^/accounts/([^/]+)/cfd_tunnel", path)
        if m:
            if method == "POST":
                body = self._read_body()
                tid = str(uuid.uuid4())
                STATE["tunnels"][tid] = body.get("name")
                return self._ok({"id": tid, "name": body.get("name"),
                                 "token": tunnel_token(m.group(1), tid)})
            # Sin filtro name= el real devuelve TODOS los tuneles de la
            # cuenta, no una lista vacia; es como se comprueba que reejecutar
            # no deja tuneles huerfanos (#15).
            wanted = re.search(r"name=([^&]+)", path)
            name = unquote(wanted.group(1)) if wanted else None
            found = [{"id": k, "name": v} for k, v in STATE["tunnels"].items()
                     if name is None or v == name]
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
