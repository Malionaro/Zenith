#!/usr/bin/env python3
"""Zenith's relay: play a Factorio server that runs on another PC.

Factorio's Lua UDP (--enable-lua-udp, helpers.send_udp and recv_udp) reaches only 127.0.0.1, so the
bridge mod can only talk to a Zenith on the server's own PC. Run this beside the server; Zenith on
another PC connects to it instead (docs/RUNNING.md, "Server on another PC"):

    python3 server/relay.py                      # TCP 34200 on every interface, LAN addresses only
    python3 server/relay.py --allow 192.168.1.0/24 --allow 10.8.0.5
    python3 server/relay.py --rcon-port 34198    # Zenith may use the server's RCON through it too

For each Zenith it opens a UDP socket of its own on 127.0.0.1, so the bridge sees an ordinary local
client (the bridge tells clients apart by the port their hello comes from), and it passes every
datagram on unchanged, both ways. A Zenith that connects again (a dropped network, a restarted
link) with the same session id gets its old port back, so the bridge sees nothing change. Standard
library only: Linux, Windows, macOS, a Raspberry Pi.

Over the network it speaks TCP, each datagram a frame (docs/PROTOCOL.md, "Over the network"). Not
UDP: the bridge fills its datagrams up to 60 KB (each send_udp costs the game about a millisecond
whatever its size), which cross a network as some 40 IP fragments, and losing any one loses the
whole datagram (a chunk snapshot, a tick's belts); Wi-Fi loses many, and a PC's socket buffer
overflows on a tick's burst. The protocol heals a loss only by asking for the chunks again. TCP
resends just the lost segment, paces the stream to what the network takes and never fragments; on a
LAN its delay is well under a frame. When a Zenith falls behind, the relay holds up to --max-buffer
for it and then drops whole datagrams, which the protocol already treats as lost (a gap, a resync).
"""

import argparse
import collections
import ipaddress
import json
import logging
import selectors
import socket
import struct
import sys
import time

GAME = b"ZRL1"  # a Zenith's game stream: frames both ways
RCON = b"ZRC1"  # a Zenith's RCON: bytes piped to the server's RCON port as they are
REFUSED = b"ZRL!"  # then a frame saying why, and the relay closes
HEADER = struct.Struct(">I")
MAX_FRAME = 1 << 20  # a datagram is at most 65,507 bytes: anything much bigger isn't Zenith
DEFAULT_PORT = 34200  # TCP, the same number as the bridge's UDP port: one address to remember
LAN = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
       "::1/128", "fc00::/7", "fe80::/10"]
# A connection that hasn't said what it is by then, and how long frames before the first hello
# wait for it (the hello carries the session id that picks the port).
GREET_SECONDS = 10.0
HELLO_WAIT_SECONDS = 3.0
HELLO_WAIT_FRAMES = 64

log = logging.getLogger("zenith-relay")


def parse_allow(items):
    """--allow values (IPs, subnets, comma or space separated, "lan", "any") as networks."""
    nets = []
    for item in items:
        for part in item.replace(",", " ").split():
            if part == "any":
                nets += [ipaddress.ip_network("0.0.0.0/0"), ipaddress.ip_network("::/0")]
            elif part == "lan":
                nets += [ipaddress.ip_network(n) for n in LAN]
            else:
                nets.append(ipaddress.ip_network(part, strict=False))
    return nets


def is_allowed(ip, nets):
    try:
        addr = ipaddress.ip_address(ip.split("%")[0])
    except ValueError:
        return False
    if addr.version == 6 and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return any(addr in net for net in nets)


def hello_sid(data):
    """The session id of a hello datagram, else None. Zenith sends one command per datagram, a hello
    about 150 bytes with its keys sorted (Godot's JSON.stringify), so "t" comes late."""
    if len(data) > 4096 or b'"hello"' not in data:
        return None
    try:
        msg = json.loads(data)
    except ValueError:
        return None
    if isinstance(msg, dict) and msg.get("t") == "hello" and msg.get("sid") is not None:
        return str(msg["sid"])
    return None


def frame(data):
    return HEADER.pack(len(data)) + data


class Stream:
    """A TCP socket with what waits to be written to it."""

    def __init__(self, sock, name, now):
        self.sock = sock
        self.name = name
        self.out = collections.deque()  # bytearrays; small writes join the last one
        self.out_at = 0  # bytes of out[0] already written
        self.out_bytes = 0
        self.writing = False  # registered for EVENT_WRITE
        self.closing = None  # close once written, saying this
        self.opened = now
        self.heard = now

    def queue(self, data):
        if not data:
            return
        if self.out and len(self.out[-1]) < 65536 and (len(self.out) > 1 or self.out_at == 0):
            self.out[-1] += data
        else:
            self.out.append(bytearray(data))
        self.out_bytes += len(data)


class Zenith(Stream):
    """One connection from a Zenith (or, until its first four bytes, from anyone allowed)."""

    def __init__(self, sock, addr, now):
        super().__init__(sock, "%s:%d" % (addr[0], addr[1]), now)
        self.ip = addr[0]
        self.kind = None  # "game" or "rcon" once it said
        self.inbuf = bytearray()
        self.link = None  # its Link to the bridge (game)
        self.waiting = []  # frames from before its first hello
        self.pipe = None  # the server's RCON (rcon)
        self.up = 0  # bytes to the bridge
        self.down = 0  # bytes from it
        self.dropped = 0  # datagrams dropped while it was behind
        self.dropped_said = 0.0


class Link:
    """A Zenith's UDP socket on 127.0.0.1: to the bridge, the client on that port."""

    def __init__(self, sock, ip, sid):
        self.sock = sock
        self.port = sock.getsockname()[1]
        self.ip = ip
        self.sid = sid
        self.zenith = None
        self.left_at = None  # when its Zenith went (kept for --keep seconds for it to come back)
        self.unsent = 0  # datagrams that came while no Zenith was connected
        self.send_errors = 0


class Relay:
    def __init__(self, host="0.0.0.0", port=DEFAULT_PORT, bridge_port=34200, allow=None, rcon_port=0,
                 max_clients=8, timeout=30.0, keep=30.0, max_buffer=8 << 20, rcvbuf=8 << 20):
        self.bridge = ("127.0.0.1", bridge_port)
        self.allow = parse_allow(allow or ["lan"])
        self.rcon_port = rcon_port
        self.max_clients = max_clients
        self.timeout = timeout
        self.keep = keep
        self.max_buffer = max_buffer
        self.rcvbuf = rcvbuf
        self.small_buffer_said = False
        self.sel = selectors.DefaultSelector()
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self.listener = socket.socket(family, socket.SOCK_STREAM)
        if family == socket.AF_INET6:
            try:
                self.listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except OSError:
                pass
        if sys.platform != "win32":
            # (On Windows SO_REUSEADDR lets a second program take the same port: never there.)
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind((host, port))
        self.listener.listen(16)
        self.listener.setblocking(False)
        self.address = self.listener.getsockname()[:2]
        self.sel.register(self.listener, selectors.EVENT_READ, ("listen", None))
        self.zeniths = set()
        self.links = set()
        self.by_sid = {}
        self.stopped = False
        self._house_at = 0.0

    # --- the loop ----------------------------------------------------------------------------

    def serve(self, stop=None):
        """Runs until stop() is called (from another thread, or a signal), or `stop` (an Event) is set."""
        while not self.stopped and not (stop is not None and stop.is_set()):
            self.step(0.25)
        self.close()

    def step(self, wait):
        for key, events in self.sel.select(wait):
            kind, obj = key.data
            if kind == "listen":
                self._accept()
            elif kind == "zenith":
                if events & selectors.EVENT_READ:
                    self._read_zenith(obj)
                if events & selectors.EVENT_WRITE and obj in self.zeniths:
                    self._flush(obj)
            elif kind == "udp":
                self._read_bridge(obj)
            elif kind == "pipe":
                # (Its Zenith may have gone earlier in this round: then its pipe went with it.)
                if events & selectors.EVENT_READ and obj.pipe is not None:
                    self._read_pipe(obj)
                if events & selectors.EVENT_WRITE and obj.pipe is not None:
                    self._flush(obj.pipe, owner=obj)
        now = time.monotonic()
        if now - self._house_at >= 0.25:
            self._house_at = now
            self._housekeeping(now)

    def stop(self):
        self.stopped = True

    def close(self):
        if self.sel.get_map() is None:
            return  # closed already
        for z in list(self.zeniths):
            self._drop(z, "the relay stopped")
        for link in list(self.links):
            self._forget(link)
        try:
            self.sel.unregister(self.listener)
        except (KeyError, ValueError):
            pass
        self.listener.close()
        self.sel.close()

    # --- Zeniths -----------------------------------------------------------------------------

    def _accept(self):
        while True:
            try:
                sock, addr = self.listener.accept()
            except (BlockingIOError, InterruptedError):
                return
            except OSError as e:
                log.warning("accept failed: %s", e)
                return
            if not is_allowed(addr[0], self.allow):
                log.info("refused %s:%d: not in --allow", addr[0], addr[1])
                sock.close()
                continue
            sock.setblocking(False)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
            except OSError:
                pass
            z = Zenith(sock, addr, time.monotonic())
            self.zeniths.add(z)
            self.sel.register(sock, selectors.EVENT_READ, ("zenith", z))
            log.debug("%s: connected", z.name)

    def _refuse(self, z, why):
        log.info("%s: refused: %s", z.name, why)
        z.queue(REFUSED + frame(why.encode()))
        z.closing = "refused"
        self._flush(z)

    def _read_zenith(self, z):
        try:
            data = z.sock.recv(1 << 18)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as e:
            self._drop(z, "connection lost (%s)" % e)
            return
        if not data:
            self._drop(z, "closed by Zenith")
            return
        z.heard = time.monotonic()
        if z.closing:
            return
        if z.kind == "rcon":
            z.pipe.queue(data)
            self._flush(z.pipe, owner=z)
            return
        z.inbuf += data
        if z.kind is None:
            if len(z.inbuf) < 4:
                return
            said = bytes(z.inbuf[:4])
            del z.inbuf[:4]
            if said == GAME:
                if sum(1 for o in self.zeniths if o.kind == "game") >= self.max_clients:
                    self._refuse(z, "the relay has %d Zeniths connected already (--max-clients)" % self.max_clients)
                    return
                z.kind = "game"
                z.queue(GAME)
                self._flush(z)
            elif said == RCON:
                self._open_rcon(z)
                return
            else:
                self._drop(z, "not a Zenith (it said %r)" % said)
                return
        buf = z.inbuf
        at = 0
        while len(buf) - at >= 4:
            (n,) = HEADER.unpack_from(buf, at)
            if n > MAX_FRAME:
                self._drop(z, "a frame of %d bytes" % n)
                return
            if len(buf) - at - 4 < n:
                break
            if n:
                self._to_bridge(z, bytes(buf[at + 4:at + 4 + n]))
                if z not in self.zeniths:
                    return
            at += 4 + n
        if at:
            del buf[:at]

    def _to_bridge(self, z, data):
        if z.link is None:
            sid = hello_sid(data)
            if sid is None and len(z.waiting) < HELLO_WAIT_FRAMES \
                    and time.monotonic() - z.opened < HELLO_WAIT_SECONDS:
                z.waiting.append(data)
                return
            self._attach(z, sid)
            waiting, z.waiting = z.waiting, []
            for d in waiting:
                self._send_bridge(z.link, d)
        self._send_bridge(z.link, data)
        z.up += len(data)

    def _send_bridge(self, link, data):
        try:
            link.sock.sendto(data, self.bridge)
        except OSError as e:
            link.send_errors += 1
            if link.send_errors == 1:
                log.warning("127.0.0.1:%d: can't send to the bridge at %s:%d: %s", link.port, *self.bridge, e)

    def _attach(self, z, sid):
        """Gives `z` its UDP socket: the one its session had (same session id, same machine), else a new one."""
        link = self.by_sid.get(sid) if sid else None
        if link is not None and link.ip != z.ip:
            link = None
        if link is not None:
            if link.zenith is not None and link.zenith is not z:
                old = link.zenith
                old.link = None
                link.zenith = None
                self._drop(old, "the same Zenith connected again")
            log.info("%s: Zenith back (session %s), on its port 127.0.0.1:%d again", z.name, sid, link.port)
        else:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.rcvbuf)
            except OSError:
                pass
            sock.bind(("127.0.0.1", 0))
            sock.setblocking(False)
            got = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
            if got < (1 << 20) and not self.small_buffer_said:
                self.small_buffer_said = True
                log.warning("the OS gave the relay only %d KB of UDP receive buffer: a busy base's burst can overflow "
                            "it (lost datagrams, then resyncs). On Linux: sudo sysctl -w net.core.rmem_max=8388608",
                            got // 1024)
            link = Link(sock, z.ip, sid)
            self.links.add(link)
            if sid:
                self.by_sid[sid] = link
            self.sel.register(sock, selectors.EVENT_READ, ("udp", link))
            log.info("%s: Zenith connected (session %s), to the bridge from 127.0.0.1:%d", z.name, sid or "?", link.port)
        link.zenith = z
        link.left_at = None
        z.link = link

    def _drop(self, z, why):
        if z not in self.zeniths:
            return
        self.zeniths.discard(z)
        try:
            self.sel.unregister(z.sock)
        except (KeyError, ValueError):
            pass
        z.sock.close()
        if z.pipe is not None:
            self._close_pipe(z)
        link = z.link
        if link is not None:
            z.link = None
            link.zenith = None
            link.left_at = time.monotonic()
        if z.kind == "game":
            seconds = time.monotonic() - z.opened
            extra = ", %d datagrams dropped while it was behind" % z.dropped if z.dropped else ""
            port = ", its port kept %d s for it to come back" % self.keep if link is not None else ""
            log.info("%s: %s after %d s (%.1f MB to it, %.1f KB from it%s)%s", z.name, why, seconds,
                     z.down / 1e6, z.up / 1e3, extra, port)
        elif z.kind == "rcon":
            log.info("%s: RCON %s", z.name, why)
        elif z.closing != "refused":
            log.info("%s: %s", z.name, why)

    def _flush(self, s, owner=None):
        """Writes what `s` has waiting. `owner`: the Zenith whose RCON pipe `s` is."""
        while s.out:
            head = s.out[0]
            try:
                n = s.sock.send(memoryview(head)[s.out_at:])
            except (BlockingIOError, InterruptedError):
                break
            except OSError as e:
                if owner is not None:
                    self._drop(owner, "the server's RCON went (%s)" % e)
                else:
                    self._drop(s, "connection lost (%s)" % e)
                return
            s.out_at += n
            s.out_bytes -= n
            if s.out_at < len(head):
                break
            s.out.popleft()
            s.out_at = 0
        want = bool(s.out)
        if want != s.writing:
            s.writing = want
            events = selectors.EVENT_READ | (selectors.EVENT_WRITE if want else 0)
            self.sel.modify(s.sock, events, ("pipe", owner) if owner is not None else ("zenith", s))
        if not s.out and owner is None and s.closing:
            self._drop(s, s.closing)

    # --- the bridge --------------------------------------------------------------------------

    def _read_bridge(self, link):
        z = link.zenith
        for _ in range(512):
            try:
                data = link.sock.recv(65536)
            except (BlockingIOError, InterruptedError):
                break
            except ConnectionResetError:
                continue  # Windows: an earlier send found nothing listening on the bridge's port
            except OSError:
                break
            if z is None:
                link.unsent += 1
                continue
            if z.out_bytes > self.max_buffer:
                z.dropped += 1
                now = time.monotonic()
                if now - z.dropped_said > 5.0:
                    z.dropped_said = now
                    log.warning("%s: Zenith is %.1f MB behind: dropping datagrams (%d so far); it asks again for "
                                "what it lost", z.name, z.out_bytes / 1e6, z.dropped)
                continue
            z.queue(frame(data))
            z.down += len(data)
        if z is not None and z in self.zeniths:
            self._flush(z)

    # --- RCON --------------------------------------------------------------------------------

    def _open_rcon(self, z):
        if not self.rcon_port:
            self._refuse(z, "this relay doesn't carry RCON (start it with --rcon-port <the server's RCON port>)")
            return
        try:
            up = socket.create_connection(("127.0.0.1", self.rcon_port), timeout=2.0)
        except OSError as e:
            self._refuse(z, "the server's RCON on port %d doesn't answer (%s)" % (self.rcon_port, e))
            return
        up.setblocking(False)
        up.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        z.kind = "rcon"
        z.pipe = Stream(up, "rcon", time.monotonic())
        self.sel.register(up, selectors.EVENT_READ, ("pipe", z))
        log.info("%s: RCON, to the server's port %d", z.name, self.rcon_port)
        z.queue(RCON)
        self._flush(z)
        if z.inbuf:
            z.pipe.queue(bytes(z.inbuf))
            z.inbuf.clear()
            self._flush(z.pipe, owner=z)

    def _read_pipe(self, z):
        try:
            data = z.pipe.sock.recv(1 << 16)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as e:
            self._drop(z, "the server's RCON went (%s)" % e)
            return
        if not data:
            self._drop(z, "closed by the server")
            return
        z.queue(data)
        self._flush(z)

    def _close_pipe(self, z):
        try:
            self.sel.unregister(z.pipe.sock)
        except (KeyError, ValueError):
            pass
        z.pipe.sock.close()
        z.pipe = None

    # --- time --------------------------------------------------------------------------------

    def _housekeeping(self, now):
        for z in list(self.zeniths):
            if z.kind is None and now - z.opened > GREET_SECONDS:
                self._drop(z, "said nothing")
            elif z.kind == "game" and now - z.heard > self.timeout:
                self._drop(z, "silent for %g s" % self.timeout)
            elif z.kind == "game" and z.link is None and z.waiting and now - z.opened > HELLO_WAIT_SECONDS:
                # Frames without a hello: give it a port of its own anyway.
                self._attach(z, None)
                waiting, z.waiting = z.waiting, []
                for d in waiting:
                    self._send_bridge(z.link, d)
        for link in list(self.links):
            if link.zenith is None and link.left_at is not None and now - link.left_at > self.keep:
                self._forget(link)

    def _forget(self, link):
        try:
            self.sel.unregister(link.sock)
        except (KeyError, ValueError):
            pass
        link.sock.close()
        self.links.discard(link)
        if link.sid and self.by_sid.get(link.sid) is link:
            del self.by_sid[link.sid]
        log.debug("127.0.0.1:%d closed (session %s)", link.port, link.sid or "?")


def lan_addresses():
    """This machine's addresses other PCs may reach it on (best effort, nothing is sent)."""
    found = set()
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith("127."):
                found.add(ip)
    except OSError:
        pass
    try:
        # A UDP "connection" only picks the route: no packet leaves.
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.254.254.254", 9))
        ip = s.getsockname()[0]
        s.close()
        if not ip.startswith("127.") and ip != "0.0.0.0":
            found.add(ip)
    except OSError:
        pass
    return sorted(found)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="docs/RUNNING.md, \"Server on another PC\", says how to set it up.")
    parser.add_argument("--host", default="0.0.0.0", help="address to listen on (default every interface; :: for IPv6 too)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port Zenith connects to (default %(default)s)")
    parser.add_argument("--bridge-port", type=int, default=34200,
                        help="the server's --enable-lua-udp port on 127.0.0.1 (default %(default)s)")
    parser.add_argument("--allow", action="append", default=[], metavar="IP_OR_SUBNET",
                        help="who may connect: IPs or subnets (192.168.1.0/24), comma separated or repeated; \"lan\" "
                             "for the private ranges (the default), \"any\" for everyone (not on the internet!)")
    parser.add_argument("--rcon-port", type=int, default=0,
                        help="the server's RCON port on 127.0.0.1 (run-server.ps1 and run-headless.sh: 34198), so Zenith "
                             "can pause the game and run console commands through the relay (default: off)")
    parser.add_argument("--max-clients", type=int, default=8, help="Zeniths at once (the bridge serves 8; default %(default)s)")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="seconds a Zenith may be silent before its connection is closed (it says hello every second)")
    parser.add_argument("--keep", type=float, default=30.0,
                        help="seconds a gone Zenith's port to the bridge is kept, for it to come back to")
    parser.add_argument("--max-buffer", type=float, default=8.0,
                        help="MB waiting for a Zenith that falls behind before datagrams are dropped (default %(default)s)")
    parser.add_argument("--log", metavar="FILE", help="also write the log to this file")
    parser.add_argument("-v", "--verbose", action="store_true", help="also log each connection as it opens and each port to the bridge as it is let go")
    args = parser.parse_args(argv)

    handlers = [logging.StreamHandler()]
    if args.log:
        handlers.append(logging.FileHandler(args.log, encoding="utf-8"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(message)s", datefmt="%H:%M:%S", handlers=handlers)
    try:
        relay = Relay(args.host, args.port, args.bridge_port, args.allow or ["lan"], args.rcon_port, args.max_clients,
                      args.timeout, args.keep, int(args.max_buffer * (1 << 20)))
    except OSError as e:
        log.error("can't listen on %s:%d: %s", args.host, args.port, e)
        return 1
    except ValueError as e:
        log.error("--allow: %s", e)
        return 2
    allow = ", ".join(str(n) for n in relay.allow)
    if any(n.prefixlen == 0 for n in relay.allow):
        log.warning("--allow any: every address may connect. Never open this port to the internet: the relay "
                    "has no password, and whoever connects plays on your server.")
    log.info("Zenith relay on TCP %s:%d, to the bridge at 127.0.0.1:%d (UDP)%s", relay.address[0], relay.address[1],
             args.bridge_port, ", RCON at 127.0.0.1:%d" % args.rcon_port if args.rcon_port else "")
    log.info("allowed: %s", allow)
    here = lan_addresses()
    if here:
        log.info("in Zenith: Play > Connect to address > %s", " or ".join("%s:%d" % (ip, relay.address[1]) for ip in here))
    try:
        relay.serve()
    except KeyboardInterrupt:
        relay.close()
    log.info("relay stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
