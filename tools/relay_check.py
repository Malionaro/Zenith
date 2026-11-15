"""Plays a bridge through server/relay.py as Zenith would, and says whether the world came through.

A Zenith stand-in over the relay's TCP: the handshake, the 3x3 chunks round the character, every
message checked against tools/protocol.py, a resync for each gap in the reliable stream (as
bridge.gd asks), then (--reconnect) the connection dropped and made again with the same session id,
which must find its old port to the bridge, and once more with a new id. Works against the mock
(tools/mock_server.py) or real Factorio behind a relay.

    python3 tools/relay_check.py --relay 192.168.1.20:34200          # a relay already running
    python3 tools/relay_check.py --bridge-port 34200 --reconnect      # starts a relay here, in front of that bridge

tools/test_relay.py runs it against the mock with lost packets.
"""

import argparse
import json
import pathlib
import socket
import struct
import sys
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "server"))
import protocol  # noqa: E402
import relay as relay_mod  # noqa: E402

HEADER = struct.Struct(">I")


class RelayClient:
    """One TCP connection to a relay, as bridge.gd's relay link: says what it is, then frames."""

    def __init__(self, host, port, kind=relay_mod.GAME, timeout=5.0, rcvbuf=0):
        self.sock = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_STREAM)
        if rcvbuf:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = bytearray()
        self.refused = None
        self.closed = False
        self.sock.sendall(kind)
        self.greeting = self._exact(4, timeout)
        if self.greeting == relay_mod.REFUSED:
            why = self.frame(timeout)
            self.refused = why.decode("utf-8", "replace") if why is not None else "?"

    def _fill(self, timeout):
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(1 << 18)
        except socket.timeout:
            return False
        except OSError:
            data = b""
        if not data:
            self.closed = True
            return False
        self.buf += data
        return True

    def _exact(self, n, timeout):
        end = time.monotonic() + timeout
        while len(self.buf) < n:
            left = end - time.monotonic()
            if left <= 0 or not self._fill(left):
                return None
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def frame(self, timeout=1.0):
        """The next datagram, or None after `timeout` (or once the relay closed)."""
        end = time.monotonic() + timeout
        while True:
            if len(self.buf) >= 4:
                (n,) = HEADER.unpack_from(self.buf, 0)
                if len(self.buf) >= 4 + n:
                    out = bytes(self.buf[4:4 + n])
                    del self.buf[:4 + n]
                    return out
            left = end - time.monotonic()
            if left <= 0 or self.closed or not self._fill(left):
                return None

    def send(self, data):
        if isinstance(data, dict):
            # Keys sorted, as Godot's JSON.stringify writes them (a hello's "t" comes late).
            data = json.dumps(data, separators=(",", ":"), sort_keys=True).encode()
        self.sock.sendall(HEADER.pack(len(data)) + data)

    def raw(self, data):
        self.sock.sendall(data)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Session:
    """The game side of a Zenith stand-in over a RelayClient: hello once a second, sequencing, resyncs."""

    def __init__(self, link, sid):
        self.link = link
        self.sid = sid
        self.welcomes = 0
        self.ready = False
        self.expected_r = None
        self.gaps = 0
        self.resyncs = 0
        self.full_resyncs = 0
        self.messages = 0
        self.datagrams = 0
        self.bytes = 0
        self.problems = []
        self.types = {}
        self.chunks = {}  # (cx, cy) -> [parts, set of ents parts seen]
        self.wanted = []
        self.pos = None
        self.last_hello = 0.0
        self.last_reliable = time.monotonic()
        self.last_resync = 0.0
        self.pending = 0  # 1 chunks, 2 full

    def hello(self):
        self.link.send({"t": "hello", "v": 1, "sid": self.sid, "w": 1 if self.welcomes else 0, "b": 1, "dq": 1, "lv": 1,
                        "mg": 0})
        self.last_hello = time.monotonic()

    def run(self, seconds, until=None):
        """Plays for up to `seconds`, or until `until(self)` is true. True when it ended by `until`."""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            now = time.monotonic()
            if now - self.last_hello >= 1.0:
                self.hello()
            data = self.link.frame(0.05)
            while data is not None:
                self._datagram(data)
                data = self.link.frame(0.0)
            if self.link.closed:
                return False
            self._resync(time.monotonic())
            if until is not None and until(self):
                return True
        return False

    def _datagram(self, data):
        self.datagrams += 1
        self.bytes += len(data)
        try:
            msgs = protocol.split_datagram(data)
        except ValueError as e:
            self.problems.append("bad JSON: %s" % e)
            return
        for msg in msgs:
            self.messages += 1
            t = msg.get("t")
            self.types[t] = self.types.get(t, 0) + 1
            if len(self.problems) < 20:
                for p in protocol.problems(msg):
                    self.problems.append("%s: %s" % (t, p))
            self._message(msg)

    def _message(self, msg):
        t = msg.get("t")
        if "r" in msg:
            r = int(msg["r"])
            self.last_reliable = time.monotonic()
            if t == "welcome":
                self.expected_r = r
            if self.expected_r is not None and r > self.expected_r:
                self.gaps += 1
                self.pending = max(self.pending, 1 if self.ready else 2)
            if self.expected_r is None or r >= self.expected_r:
                self.expected_r = r + 1
        if t == "welcome":
            self.welcomes += 1
            self.ready = False
            self.chunks = {}
            x, y = int(msg.get("x", 0)) / 256.0, int(msg.get("y", 0)) / 256.0
            self.pos = (x, y)
        elif t == "ready":
            self.ready = True
            self._subscribe()
        elif t == "chunk":
            key = (int(msg["cx"]), int(msg["cy"]))
            if key in self.chunks:
                parts = 0 if msg.get("none") or msg.get("same") else int(msg.get("parts", 0))
                self.chunks[key][0] = parts
        elif t == "ents":
            key = (int(msg["cx"]), int(msg["cy"]))
            if key in self.chunks:
                self.chunks[key][1].add(int(msg.get("part", 1)))

    def _subscribe(self):
        cx, cy = int(self.pos[0] // 32), int(self.pos[1] // 32)
        self.wanted = [[cx + dx, cy + dy] for dy in (-1, 0, 1) for dx in (-1, 0, 1)]
        self.chunks = {(c[0], c[1]): [None, set()] for c in self.wanted}
        self.link.send({"t": "sub", "c": self.wanted})
        self.link.send({"t": "focus", "x": int(self.pos[0] * 256), "y": int(self.pos[1] * 256), "r": 64})

    def incomplete(self):
        return [[k[0], k[1]] for k, (parts, seen) in self.chunks.items()
                if parts is None or len(seen) < parts]

    def complete(self):
        return self.ready and self.chunks and not self.incomplete()

    def _resync(self, now):
        # As bridge.gd: the handshake's end lost (nothing reliable for 3 s while not ready) starts it
        # over; a chunk still incomplete while the stream is quiet is asked for again.
        if self.welcomes and not self.ready and now - self.last_reliable > 3.0:
            self.pending = 2
        if self.ready and self.incomplete() and now - self.last_reliable > 1.0:
            self.pending = max(self.pending, 1)
        if not self.pending:
            return
        full = self.pending == 2
        if now - self.last_resync < (2.5 if full else 0.5):
            return
        self.last_resync = now
        self.pending = 0
        if full:
            self.full_resyncs += 1
            self.link.send({"t": "resync", "full": 1})
        elif self.incomplete():
            self.resyncs += 1
            # The subscription again first: a lost `sub` (commands are lost too, over UDP behind the relay)
            # leaves nothing subscribed, and a resync only resends subscribed chunks. The same list changes nothing.
            self.link.send({"t": "sub", "c": self.wanted})
            self.link.send({"t": "resync", "full": 0, "c": self.incomplete()})

    def summary(self):
        done = len(self.chunks) - len(self.incomplete()) if self.chunks else 0
        return ("%d datagrams (%.1f KB), %d messages, %d welcome(s), ready %s, chunks %d/%d, %d gaps, %d chunk "
                "resyncs, %d full resyncs, %d protocol problems") % (
            self.datagrams, self.bytes / 1e3, self.messages, self.welcomes, self.ready, done, len(self.chunks),
            self.gaps, self.resyncs, self.full_resyncs, len(self.problems))


def start_relay(bridge_port, **options):
    """A relay in this process on a free port in front of `bridge_port`: (relay, thread, stop event)."""
    relay = relay_mod.Relay("127.0.0.1", 0, bridge_port, options.pop("allow", ["127.0.0.1"]), **options)
    stop = threading.Event()
    thread = threading.Thread(target=relay.serve, args=(stop,), daemon=True)
    thread.start()
    return relay, thread, stop


def check(host, port, seconds=30.0, reconnect=False, relay=None, say=print):
    """Plays through the relay at host:port; returns a list of failures (empty: all came through)."""
    failures = []
    sid = "relay-check-%d" % int(time.time() * 1000)
    link = RelayClient(host, port)
    if link.refused is not None:
        return ["the relay refused: " + link.refused]
    if link.greeting != relay_mod.GAME:
        return ["no relay at %s:%d (it answered %r)" % (host, port, link.greeting)]
    s = Session(link, sid)
    s.hello()
    whole = s.run(seconds, lambda x: x.complete())
    say("first connection: " + s.summary())
    if not whole:
        failures.append("the world didn't come through in %d s: %s" % (seconds, s.summary()))
    failures += ["protocol: " + p for p in s.problems[:5]]
    if failures or not reconnect:
        link.close()
        return failures
    port_before = relay.by_sid[sid].port if relay is not None and sid in relay.by_sid else None

    # The same Zenith again (a dropped connection): the same session goes on, nothing new to load.
    link.close()
    time.sleep(0.3)
    link = RelayClient(host, port)
    s.link = link
    welcomes, datagrams = s.welcomes, s.datagrams
    s.hello()
    went_on = s.run(10.0, lambda x: x.datagrams >= datagrams + 20)
    say("same session again: " + s.summary())
    if not went_on:
        failures.append("after connecting again with the same session, the stream didn't go on")
    if s.welcomes != welcomes:
        failures.append("the same session connected again was welcomed anew (the bridge saw a new port)")
    if relay is not None:
        port_after = relay.by_sid[sid].port if sid in relay.by_sid else None
        if port_before is None or port_after != port_before:
            failures.append("the same session got another port to the bridge: %s, then %s" % (port_before, port_after))
    link.close()

    # A new session (Zenith restarted): welcomed, and the world comes again.
    time.sleep(0.3)
    link = RelayClient(host, port)
    s2 = Session(link, sid + "-new")
    s2.hello()
    whole = s2.run(seconds, lambda x: x.complete())
    say("a new session: " + s2.summary())
    if not whole:
        failures.append("a new session didn't get the world: " + s2.summary())
    link.close()
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--relay", help="host:port of a running relay")
    parser.add_argument("--bridge-port", type=int, help="start a relay here, in front of this bridge port")
    parser.add_argument("--seconds", type=float, default=30.0, help="how long the world may take to come")
    parser.add_argument("--reconnect", action="store_true", help="also drop the connection and come back, then a new session")
    args = parser.parse_args()
    relay = None
    if args.relay:
        host, _, port = args.relay.rpartition(":")
        host, port = host.strip("[]") or "127.0.0.1", int(port)
    elif args.bridge_port:
        relay, _, stop = start_relay(args.bridge_port)
        host, port = relay.address
        print("relay on %s:%d in front of the bridge at 127.0.0.1:%d" % (host, port, args.bridge_port))
    else:
        parser.error("--relay or --bridge-port")
    failures = check(host, port, args.seconds, args.reconnect, relay)
    if relay is not None:
        stop.set()
    for f in failures:
        print("FAIL:", f)
    print("relay check: %s" % ("FAILED" if failures else "OK"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
