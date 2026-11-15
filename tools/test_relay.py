"""Tests server/relay.py over real localhost sockets: a fake bridge (a UDP socket, as Factorio's
--enable-lua-udp port) and Zenith stand-ins over TCP, then tools/mock_server.py behind the relay
losing 5% of its packets, with a Zenith that drops its connection and comes back.

    python3 tools/test_relay.py            # about half a minute
    python3 tools/test_relay.py --quick    # without the mock
    python3 tools/test_relay.py -v         # with the relay's own log
"""

import json
import logging
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "server"))
import relay as relay_mod  # noqa: E402
import relay_check  # noqa: E402
from relay_check import RelayClient  # noqa: E402

failures = []
# The relay's own log (refusals, drops) only with -v: the checks say what happened.
logging.basicConfig(level=logging.INFO if "-v" in sys.argv else logging.ERROR, format="      relay: %(message)s")


def check(cond, what):
    print(("ok:   " if cond else "FAIL: ") + what)
    if not cond:
        failures.append(what)


def hello(sid):
    # As Zenith's: RelayClient.send sorts the keys as Godot's JSON.stringify does, which puts "t" past the
    # first 64 bytes (a relay that looked only there never found a real Zenith's session).
    return {"t": "hello", "v": 1, "sid": sid, "w": 0, "b": 1, "bs": 1, "dc": 1, "dd": 192, "dq": 1, "lv": 1, "mg": 0, "z": 1}


class FakeBridge:
    """The bridge's UDP port: what came from which port, and datagrams back to a port."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]

    def take(self, count=1, timeout=2.0):
        """Up to `count` datagrams as (bytes, source port)."""
        out = []
        end = time.monotonic() + timeout
        while len(out) < count:
            left = end - time.monotonic()
            if left <= 0:
                break
            self.sock.settimeout(left)
            try:
                data, addr = self.sock.recvfrom(65536)
            except socket.timeout:
                break
            except ConnectionResetError:
                continue
            out.append((data, addr[1]))
        return out

    def send(self, port, data):
        self.sock.sendto(data, ("127.0.0.1", port))


def start(bridge, **options):
    relay, thread, stop = relay_check.start_relay(bridge.port, **options)
    return relay, stop


def connect(relay, **kw):
    return RelayClient(relay.address[0], relay.address[1], **kw)


def wait_until(cond, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return cond()


# --- the allow list, without sockets ---------------------------------------------------------------
lan = relay_mod.parse_allow(["lan"])
check(relay_mod.is_allowed("192.168.1.20", lan) and relay_mod.is_allowed("10.0.0.5", lan)
      and relay_mod.is_allowed("172.20.1.1", lan) and relay_mod.is_allowed("127.0.0.1", lan),
      "the default allows the private ranges and this PC")
check(not relay_mod.is_allowed("8.8.8.8", lan) and not relay_mod.is_allowed("172.32.0.1", lan)
      and not relay_mod.is_allowed("100.64.0.1", lan), "... and nothing on the internet")
check(relay_mod.is_allowed("::ffff:192.168.1.20", lan) and relay_mod.is_allowed("fe80::1%eth0", lan)
      and not relay_mod.is_allowed("2001:db8::1", lan), "IPv6: v4-mapped and link-local addresses read as LAN")
some = relay_mod.parse_allow(["192.168.1.0/24, 10.8.0.5"])
check(relay_mod.is_allowed("192.168.1.77", some) and relay_mod.is_allowed("10.8.0.5", some)
      and not relay_mod.is_allowed("192.168.2.1", some) and not relay_mod.is_allowed("10.8.0.6", some),
      "--allow takes subnets and single addresses, comma separated")
check(relay_mod.hello_sid(json.dumps(hello("abc"), separators=(",", ":"), sort_keys=True).encode()) == "abc"
      and relay_mod.hello_sid(b'{"t":"focus","x":1}') is None and relay_mod.hello_sid(b'{"t":"hello"') is None,
      "the session id is read from a hello only")

# --- datagrams both ways, unchanged, a port per Zenith ----------------------------------------------
bridge = FakeBridge()
relay, stop = start(bridge)
a = connect(relay)
check(a.greeting == relay_mod.GAME, "a Zenith is greeted")
a.send(hello("a"))
got = bridge.take()
check(len(got) == 1 and json.loads(got[0][0])["sid"] == "a", "its hello reaches the bridge as it was sent")
port_a = got[0][1] if got else 0
big = b"\n".join(json.dumps({"t": "sky", "k": i, "pad": "x" * 1200}).encode() for i in range(48))[:60000]
bridge.send(port_a, big)
bridge.send(port_a, b'{"t":"me","k":5}')
check(a.frame(2.0) == big and a.frame(2.0) == b'{"t":"me","k":5}',
      "the bridge's datagrams reach it whole and in order (a 60,000-byte batch, then a small one)")
for i in range(20):
    a.send({"t": "focus", "x": i, "y": 0, "r": 10})
cmds = bridge.take(20)
check(len(cmds) == 20 and all(json.loads(d)["x"] == i and p == port_a for i, (d, p) in enumerate(cmds)),
      "its commands reach the bridge in order, all from its port")

b = connect(relay)
b.send(hello("b"))
got = bridge.take()
port_b = got[0][1] if got else 0
check(port_b and port_b != port_a, "a second Zenith gets a port of its own (%d, %d): the bridge's second client" % (port_a, port_b))
bridge.send(port_b, b'{"t":"me","k":6}')
check(b.frame(2.0) == b'{"t":"me","k":6}' and a.frame(0.3) is None, "... and only its own datagrams")

# --- coming back ---------------------------------------------------------------------------------------
a.close()
check(wait_until(lambda: relay.by_sid.get("a") is not None and relay.by_sid["a"].zenith is None),
      "a Zenith that goes keeps its port for a while")
bridge.send(port_a, b'{"t":"me","k":7}')  # meanwhile: dropped, as UDP would
a2 = connect(relay)
a2.send(hello("a"))
got = bridge.take()
check(got and got[0][1] == port_a, "the same session connecting again gets its old port back (the bridge sees nothing change)")
bridge.send(port_a, b'{"t":"me","k":8}')
check(a2.frame(2.0) == b'{"t":"me","k":8}', "... and the bridge's datagrams again (none from while it was gone)")

a3 = connect(relay)
a3.send(hello("a"))
got = bridge.take()
check(got and got[0][1] == port_a and wait_until(lambda: a2.frame(0.05) is None and a2.closed),
      "the same session on a new connection while the old one hangs takes its place: the old one is closed")

c = connect(relay)
c.send({"t": "focus", "x": 1, "y": 2, "r": 3})
c.send(hello("c"))
got = bridge.take(2)
check(len(got) == 2 and json.loads(got[0][0])["t"] == "focus" and got[0][1] == got[1][1] and got[0][1] not in (port_a, port_b),
      "commands before the first hello wait for it, then go from the session's own port")
a4 = connect(relay)
a4.send(hello("a-restarted"))
got = bridge.take()
check(got and got[0][1] not in (port_a, port_b), "a new session (Zenith restarted) gets a new port")

# --- not Zenith, not allowed, too many ----------------------------------------------------------------
junk = RelayClient.__new__(RelayClient)
junk.sock = socket.create_connection(relay.address, timeout=2.0)
junk.sock.sendall(b"GET / HTTP/1.1\r\n\r\n")
junk.sock.settimeout(2.0)
try:
    answer = junk.sock.recv(100)
except OSError:
    answer = b""
check(answer == b"", "something that isn't Zenith is closed without an answer")
junk.sock.close()
stop.set()
for z in (b, a3, c, a4):
    z.close()

relay, stop = start(bridge, allow=["10.0.0.0/8"])
sock = socket.create_connection(relay.address, timeout=2.0)
sock.sendall(relay_mod.GAME)
sock.settimeout(2.0)
try:
    answer = sock.recv(100)
except OSError:
    answer = b""
check(answer == b"", "an address outside --allow is closed without an answer")
sock.close()
stop.set()

relay, stop = start(bridge, max_clients=1)
one = connect(relay)
two = connect(relay)
check(one.greeting == relay_mod.GAME and two.greeting == relay_mod.REFUSED and "max-clients" in (two.refused or ""),
      "past --max-clients a Zenith is told why: %r" % two.refused)
one.close()
two.close()

# --- RCON ---------------------------------------------------------------------------------------------
norcon = connect(relay, kind=relay_mod.RCON)
check(norcon.greeting == relay_mod.REFUSED and "rcon-port" in (norcon.refused or ""),
      "RCON through a relay without --rcon-port is refused, saying how")
norcon.close()
stop.set()

rcon_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
rcon_server.bind(("127.0.0.1", 0))
rcon_server.listen(1)
relay, stop = start(bridge, rcon_port=rcon_server.getsockname()[1])
r = connect(relay, kind=relay_mod.RCON)
r.raw(b"\x0a\x00\x00\x00login")
rcon_server.settimeout(2.0)
up, _ = rcon_server.accept()
up.settimeout(2.0)
seen = b""
while len(seen) < 9:
    seen += up.recv(100)
up.sendall(b"answer-bytes")
r.sock.settimeout(2.0)
back = r.buf + r.sock.recv(100)
check(r.greeting == relay_mod.RCON and seen == b"\x0a\x00\x00\x00login" and bytes(back) == b"answer-bytes",
      "RCON is piped to the server's RCON port and back, byte for byte")
up.close()
check(wait_until(lambda: r._fill(0.05) is False and r.closed), "... and closed when the server closes it")
r.close()
rcon_server.close()
stop.set()

# --- silence and memory ---------------------------------------------------------------------------------
relay, stop = start(bridge, timeout=0.6, keep=0.6)
quiet = connect(relay)
quiet.send(hello("quiet"))
bridge.take()
check(wait_until(lambda: quiet.frame(0.05) is None and quiet.closed, 3.0), "a Zenith silent past --timeout is closed")
check(wait_until(lambda: not relay.links, 3.0), "... and its port to the bridge is let go after --keep")
quiet.close()
stop.set()

relay, stop = start(bridge, max_buffer=256 << 10)
slow = connect(relay, rcvbuf=64 << 10)
slow.send(hello("slow"))
port_slow = bridge.take()[0][1]
payload = bytes(range(256)) * 234  # 59,904 bytes
sent = 300
for i in range(sent):
    bridge.send(port_slow, i.to_bytes(4, "big") + payload)
    if i % 8 == 7:
        time.sleep(0.004)
time.sleep(0.5)
behind = next(iter(relay.zeniths)).dropped if relay.zeniths else 0
seen = []
while True:
    d = slow.frame(1.0)
    if d is None:
        break
    seen.append(d)
whole = all(len(d) == 4 + len(payload) and d[4:] == payload for d in seen)
order = [int.from_bytes(d[:4], "big") for d in seen]
check(behind > 0 and 0 < len(seen) < sent and whole and order == sorted(order),
      "a Zenith that doesn't keep up: the relay holds --max-buffer, then drops whole datagrams (%d of %d came, "
      "%d dropped, each whole, in order)" % (len(seen), sent, behind))
slow.close()
stop.set()
bridge.sock.close()

# --- the mock behind the relay, losing packets ----------------------------------------------------------
if "--quick" not in sys.argv:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.bind(("127.0.0.1", 0))
    mock_port = probe.getsockname()[1]
    probe.close()
    # Its output to a file, not a pipe nobody reads while it runs (a full pipe would stop it).
    mock_log = tempfile.TemporaryFile()
    mock = subprocess.Popen([sys.executable, str(HERE / "mock_server.py"), "--host", "127.0.0.1", "--port", str(mock_port),
                             "--drop", "0.05"], stdout=mock_log, stderr=subprocess.STDOUT)
    try:
        time.sleep(1.0)
        relay, stop = start(type("B", (), {"port": mock_port})())
        lines = []
        problems = relay_check.check(relay.address[0], relay.address[1], seconds=40.0, reconnect=True, relay=relay,
                                     say=lambda s: lines.append(s))
        for line in lines:
            print("      " + line)
        check(not problems, "the mock behind the relay losing 5%% of its packets: the world comes through, the same "
              "session comes back on its port, a new one is welcomed%s" % ("" if not problems else ": " + "; ".join(problems)))
        stop.set()
    finally:
        mock.terminate()
        try:
            mock.wait(5)
        except subprocess.TimeoutExpired:
            mock.kill()
        mock_log.seek(0)
        out = mock_log.read().decode("utf-8", "replace").strip()
        mock_log.close()
        if failures and out:
            print("      the mock's last output:\n" + out[-2000:])

print("\n%d failure(s)" % len(failures) if failures else "\nall relay checks passed")
sys.exit(1 if failures else 0)
