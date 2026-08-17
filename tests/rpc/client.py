"""Minimal EchoCAD automation client (stdlib only).

Usage:
    from client import EchoCad
    app = EchoCad(port=4777)
    app.wait_ready()
    mode = app.call("query.mode")
    app.call("input.drag", {"from": [400, 300], "to": [500, 340]})
"""

import json
import socket
import subprocess
import time


class RpcError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class EchoCad:
    def __init__(self, port=4777, host="127.0.0.1", timeout=20.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock = None
        self._buf = b""
        self._next_id = 0

    # -- connection ---------------------------------------------------------

    def wait_ready(self, deadline=25.0):
        """Poll until the app's server accepts a connection."""
        end = time.monotonic() + deadline
        last = None
        while time.monotonic() < end:
            try:
                self._connect()
                self.call("app.info")
                return self
            except (OSError, RpcError) as e:
                last = e
                self._sock = None
                time.sleep(0.15)
        raise TimeoutError(f"server never became ready: {last}")

    def _connect(self):
        if self._sock is not None:
            return
        s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        s.settimeout(self.timeout)
        self._sock = s
        self._buf = b""

    def close(self):
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    # -- rpc ----------------------------------------------------------------

    def call(self, cmd, args=None):
        self._connect()
        self._next_id += 1
        req = {"id": self._next_id, "cmd": cmd, "args": args or {}}
        self._sock.sendall((json.dumps(req) + "\n").encode())
        while True:
            resp = self._read_line()
            if resp.get("id") != self._next_id:
                continue  # stale reply from a previous timeout
            if not resp.get("ok"):
                err = resp.get("error") or {}
                raise RpcError(err.get("code", "?"), err.get("message", "?"))
            return resp.get("result")

    def _read_line(self):
        while b"\n" not in self._buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise OSError("connection closed")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return json.loads(line)

    # -- sugar --------------------------------------------------------------

    def world_to_screen(self, p):
        return self.call("query.world_to_screen", {"p": list(p)})["p"]

    def click_world(self, p, **kw):
        return self.call("input.click", {"at": self.world_to_screen(p), **kw})

    def click_control(self, name):
        r = self.call("query.control", {"name": name})
        if not r["visible"]:
            raise RpcError("bad_state", f"control {name} not visible")
        x, y, w, h = r["rect"]
        cx, cy = x + w / 2, y + h / 2
        win = self.call("app.window")["size"]
        if not (0 <= cx <= win[0] and 0 <= cy <= win[1]):
            raise RpcError("off_window",
                           f"{name} center ({cx:.0f},{cy:.0f}) outside window {win}")
        return self.call("input.click", {"at": [cx, cy]})

    def entities(self, include_origin=False, **kw):
        """Entities in a sketch, EXCLUDING its origin point by default.

        Every sketch owns an origin point at (0,0) so geometry can be
        dimensioned from it. It is a real entity, but it is scaffolding rather
        than something a tool drew, so counting/slicing authored geometry means
        leaving it out. Pass include_origin=True to see it.
        """
        ents = self.call("query.entities", kw)["entities"]
        if include_origin:
            return ents
        return [e for e in ents if not e.get("origin")]

    def entity_map(self, **kw):
        """id -> entity for EVERY entity, origin included.

        Lookup is a different job from counting: geometry may legitimately
        reference the origin point (welding an endpoint onto it), so a map used
        to resolve those references must be complete.
        """
        return {e["id"]: e for e in self.entities(include_origin=True, **kw)}

    def constraints(self, **kw):
        return self.call("query.constraints", kw)["constraints"]

    def entities_of_kind(self, kind, **kw):
        return [e for e in self.entities(**kw) if e["kind"] == kind]


def launch(godot, project_dir, port=4777, headless=False, extra=()):
    """Launch the app with the automation server enabled; returns Popen."""
    cmd = [godot, "--path", project_dir]
    if headless:
        cmd.append("--headless")
    cmd += list(extra) + ["--", f"--automation-port={port}"]
    return subprocess.Popen(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def near(a, b, tol=1e-3):
    return abs(a - b) <= tol


def vec_near(a, b, tol=1e-3):
    return all(abs(x - y) <= tol for x, y in zip(a, b))
