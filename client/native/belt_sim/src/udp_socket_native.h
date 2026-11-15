// UdpSocketNative: a UDP socket with a receive buffer of its own size, for bridge.gd's I/O thread
// (--udp-socket=native, the default when this extension is loaded). Godot's PacketPeerUDP leaves the
// OS socket's buffer at the OS default (Windows: 64 KB; its bind()'s recv_buf_size is only Godot's
// own ring), and the bridge's tick bursts (several datagrams of up to 60 KB within a millisecond)
// overflow it: a datagram arriving when 64 KB is already queued is dropped, measured at -62,-26 as
// lost `bs` parts and `ih` updates. This socket asks for SO_RCVBUF of what bind() is given
// (megabytes), and wait() blocks on select() until a datagram is there, so the thread wakes as it
// arrives instead of sleeping (OS.delay_usec(1000) is 2 ms on Windows).
//
// Used from one thread at a time (bridge.gd's I/O thread; is_bound() may be read from another).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace godot {

class UdpSocketNative : public RefCounted {
	GDCLASS(UdpSocketNative, RefCounted)

public:
	UdpSocketNative();
	~UdpSocketNative();

	// Opens the socket, asks for a receive buffer of recv_buffer_bytes (SO_RCVBUF; the OS may give
	// another size: receive_buffer_size() says) and binds it to host:port, non-blocking. Godot Error
	// codes: OK, ERR_ALREADY_IN_USE (the port is taken), ERR_CANT_CREATE, ERR_CANT_OPEN.
	int bind(int port, const String &host, int recv_buffer_bytes);
	bool is_bound() const;
	void close();
	// Where put_packet sends to.
	void set_dest_address(const String &host, int port);
	int put_packet(const PackedByteArray &data);
	// The next datagram waiting, or an empty array when none is.
	PackedByteArray get_packet();
	// Waits up to usec microseconds for a datagram; true when one is there.
	bool wait(int usec);
	// The port bound (bind(0) takes any free one); 0 before bind.
	int get_local_port() const;
	// The receive buffer the OS gave (SO_RCVBUF, bytes); 0 before bind.
	int receive_buffer_size() const;
	// The last OS error code (WSAGetLastError / errno), for messages.
	int last_error() const;
	// Datagrams and bytes read since bind.
	int64_t packets_read() const;
	int64_t bytes_read() const;

protected:
	static void _bind_methods();

private:
	intptr_t sock = -1;
	bool bound = false;
	int err = 0;
	int rcvbuf = 0;
	int64_t n_read = 0;
	int64_t b_read = 0;
	uint32_t dest_ip = 0;
	uint16_t dest_port = 0;
	uint8_t buffer[65536];
	static bool parse_ip(const String &host, uint32_t &out);
};

} // namespace godot
