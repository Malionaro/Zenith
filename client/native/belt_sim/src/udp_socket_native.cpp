#include "udp_socket_native.h"

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
typedef int socklen_t;
typedef SOCKET sock_t;
#define SOCK_INVALID INVALID_SOCKET
#define sock_errno() WSAGetLastError()
#define SOCK_EWOULDBLOCK WSAEWOULDBLOCK
#define SOCK_EADDRINUSE WSAEADDRINUSE
#define sock_close(s) closesocket(s)
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int sock_t;
#define SOCK_INVALID (-1)
#define sock_errno() errno
#define SOCK_EWOULDBLOCK EWOULDBLOCK
#define SOCK_EADDRINUSE EADDRINUSE
#define sock_close(s) ::close(s)
#endif

#include <cstring>

using namespace godot;

// Godot's Error codes, returned as int (godot_cpp/classes/global_constants.hpp).
static const int E_OK = godot::OK;
static const int E_CANT_OPEN = godot::ERR_CANT_OPEN;
static const int E_CANT_CREATE = godot::ERR_CANT_CREATE;
static const int E_ALREADY_IN_USE = godot::ERR_ALREADY_IN_USE;
static const int E_UNCONFIGURED = godot::ERR_UNCONFIGURED;
static const int E_UNAVAILABLE = godot::ERR_UNAVAILABLE;

#ifdef _WIN32
static bool winsock_ready = false;
static void winsock_init() {
	if (!winsock_ready) {
		WSADATA data;
		if (WSAStartup(MAKEWORD(2, 2), &data) == 0) {
			winsock_ready = true;
		}
	}
}
#endif

UdpSocketNative::UdpSocketNative() {
#ifdef _WIN32
	winsock_init();
#endif
	sock = (intptr_t)SOCK_INVALID;
}

UdpSocketNative::~UdpSocketNative() {
	close();
}

bool UdpSocketNative::parse_ip(const String &host, uint32_t &out) {
	if (host.is_empty() || host == "*") {
		out = htonl(INADDR_ANY);
		return true;
	}
	CharString s = host.utf8();
	in_addr a;
	if (inet_pton(AF_INET, s.get_data(), &a) == 1) {
		out = a.s_addr;
		return true;
	}
	return false;
}

int UdpSocketNative::bind(int port, const String &host, int recv_buffer_bytes) {
	close();
	uint32_t ip;
	if (!parse_ip(host, ip)) {
		err = 0;
		return E_CANT_OPEN;
	}
	sock_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (s == SOCK_INVALID) {
		err = sock_errno();
		return E_CANT_CREATE;
	}
	sock = (intptr_t)s;
	if (recv_buffer_bytes > 0) {
		int want = recv_buffer_bytes;
		setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&want, sizeof(want));
	}
	int snd = 1 << 20;
	setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&snd, sizeof(snd));
	sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);
	addr.sin_addr.s_addr = ip;
	if (::bind(s, (const sockaddr *)&addr, sizeof(addr)) != 0) {
		err = sock_errno();
		int code = err == SOCK_EADDRINUSE ? E_ALREADY_IN_USE : E_CANT_OPEN;
		sock_close(s);
		sock = (intptr_t)SOCK_INVALID;
		return code;
	}
#ifdef _WIN32
	u_long nonblock = 1;
	ioctlsocket(s, FIONBIO, &nonblock);
#else
	int flags = fcntl(s, F_GETFL, 0);
	fcntl(s, F_SETFL, flags | O_NONBLOCK);
#endif
	int got = 0;
	socklen_t len = sizeof(got);
	if (getsockopt(s, SOL_SOCKET, SO_RCVBUF, (char *)&got, &len) == 0) {
		rcvbuf = got;
	}
	bound = true;
	n_read = 0;
	b_read = 0;
	return E_OK;
}

bool UdpSocketNative::is_bound() const {
	return bound;
}

void UdpSocketNative::close() {
	if (sock != (intptr_t)SOCK_INVALID) {
		sock_close((sock_t)sock);
		sock = (intptr_t)SOCK_INVALID;
	}
	bound = false;
	rcvbuf = 0;
}

void UdpSocketNative::set_dest_address(const String &host, int port) {
	uint32_t ip;
	if (!parse_ip(host, ip) || ip == htonl(INADDR_ANY)) {
		ip = htonl(INADDR_LOOPBACK);
	}
	dest_ip = ip;
	dest_port = (uint16_t)port;
}

int UdpSocketNative::put_packet(const PackedByteArray &data) {
	if (!bound) {
		return E_UNCONFIGURED;
	}
	sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(dest_port);
	addr.sin_addr.s_addr = dest_ip;
	sock_t s = (sock_t)sock;
	int sent = (int)sendto(s, (const char *)data.ptr(), (int)data.size(), 0, (const sockaddr *)&addr, sizeof(addr));
	if (sent < 0) {
		err = sock_errno();
		return E_UNAVAILABLE;
	}
	return E_OK;
}

PackedByteArray UdpSocketNative::get_packet() {
	PackedByteArray out;
	if (!bound) {
		return out;
	}
	sock_t s = (sock_t)sock;
	sockaddr_in from;
	socklen_t from_len = sizeof(from);
	int got = (int)recvfrom(s, (char *)buffer, sizeof(buffer), 0, (sockaddr *)&from, &from_len);
	if (got < 0) {
		int e = sock_errno();
		if (e != SOCK_EWOULDBLOCK) {
			err = e;
		}
		return out;
	}
	n_read += 1;
	b_read += got;
	out.resize(got);
	memcpy(out.ptrw(), buffer, got);
	return out;
}

bool UdpSocketNative::wait(int usec) {
	if (!bound) {
		return false;
	}
	sock_t s = (sock_t)sock;
	fd_set set;
	FD_ZERO(&set);
	FD_SET(s, &set);
	timeval tv;
	tv.tv_sec = usec / 1000000;
	tv.tv_usec = usec % 1000000;
	int r = select((int)s + 1, &set, nullptr, nullptr, &tv);
	return r > 0;
}

int UdpSocketNative::get_local_port() const {
	if (!bound) {
		return 0;
	}
	sockaddr_in addr;
	socklen_t len = sizeof(addr);
	if (getsockname((sock_t)sock, (sockaddr *)&addr, &len) != 0) {
		return 0;
	}
	return ntohs(addr.sin_port);
}

int UdpSocketNative::receive_buffer_size() const {
	return rcvbuf;
}

int UdpSocketNative::last_error() const {
	return err;
}

int64_t UdpSocketNative::packets_read() const {
	return n_read;
}

int64_t UdpSocketNative::bytes_read() const {
	return b_read;
}

void UdpSocketNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("bind", "port", "host", "recv_buffer_bytes"), &UdpSocketNative::bind);
	ClassDB::bind_method(D_METHOD("is_bound"), &UdpSocketNative::is_bound);
	ClassDB::bind_method(D_METHOD("close"), &UdpSocketNative::close);
	ClassDB::bind_method(D_METHOD("set_dest_address", "host", "port"), &UdpSocketNative::set_dest_address);
	ClassDB::bind_method(D_METHOD("put_packet", "data"), &UdpSocketNative::put_packet);
	ClassDB::bind_method(D_METHOD("get_packet"), &UdpSocketNative::get_packet);
	ClassDB::bind_method(D_METHOD("wait", "usec"), &UdpSocketNative::wait);
	ClassDB::bind_method(D_METHOD("get_local_port"), &UdpSocketNative::get_local_port);
	ClassDB::bind_method(D_METHOD("receive_buffer_size"), &UdpSocketNative::receive_buffer_size);
	ClassDB::bind_method(D_METHOD("last_error"), &UdpSocketNative::last_error);
	ClassDB::bind_method(D_METHOD("packets_read"), &UdpSocketNative::packets_read);
	ClassDB::bind_method(D_METHOD("bytes_read"), &UdpSocketNative::bytes_read);
}
