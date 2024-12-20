package protocol

import "base:runtime"
import queue "core:container/queue"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:net"

// The idea for the interception "system" is to mimic packet loss, out-of-order packets
// and other conditions that can happen in real networks specifically for how the 
// transmission module should deal with it. This will not be a realistic network emulator.
// 
// We'll achieve this by making a new Send and Recv stream that instead of writing onto a UDP
// socket, it'll somehow intercept the packets going from the Send -> Recv, whether that's through a 
// own interception queue or not is yet to be decided. Then we apply some effect on the packet, like
// drop, lag, change contents etc, and make the packets available for the recv side when the effect has
// been applied.
//
// The main advantage of doing it like this is that we get complete control over both sides, and can ensure
// that everything is synced to what we expect. 
// An example is: We want to transmit a large data structure that will be way larger than MTU so we need to split
// into, let's say 10 fragment packets. We now want to test if our protocol implementation can deal with packet loss
// properly, so we drop the third fragment. On the receiving side we can now assert that only 9 of the fragments should
// be received. Now we can do something similar for out-of-order, lag etc.

Effect :: enum {
	Drop,
	Lag,
	Corrupt,
	Duplicate,
}

Socket_Type :: enum {
	Interception,
	UDP,
}

Interception_Probabilities :: struct {
	drop: f32,
}

Interception_Socket :: struct {
	probabilities:   Interception_Probabilities,
	packet_queue:    queue.Queue([]u8),
	dropped_packets: [dynamic][]u8,
	outgoing_queue:  queue.Queue([]u8),
}

UDP_Socket :: struct {
	send: net.UDP_Socket,
	recv: net.UDP_Socket,
}

UDP_Config :: struct {
	address:   string,
	send_port: int,
	recv_port: int,
}

Interception_Config :: struct {
	probabilities: Interception_Probabilities,
}

Socket_Config :: union {
	Interception_Config,
	UDP_Config,
}

create_socket :: proc(config: Socket_Config) -> (Socket, bool) {
	switch conf in config {
	case Interception_Config:
		interception_socket := Interception_Socket {
			probabilities = conf.probabilities,
		}
		packet_queue_alloc_err := queue.init(&interception_socket.packet_queue)

		if packet_queue_alloc_err != nil {
			return Interception_Socket{}, false
		}

		outgoing_queue_alloc_err := queue.init(&interception_socket.outgoing_queue)

		if outgoing_queue_alloc_err != nil {
			return Interception_Socket{}, false
		}

		return interception_socket, true
	case UDP_Config:
		addr := net.parse_address(conf.address)
		send_socket, send_err := net.make_bound_udp_socket(addr, conf.send_port)
		if send_err != nil {
			return UDP_Socket{}, false
		}

		recv_socket, recv_err := net.make_bound_udp_socket(addr, conf.recv_port)
		if recv_err != nil {
			return UDP_Socket{}, false
		}

		blocking_err := net.set_blocking(recv_socket, false)

		udp_socket := UDP_Socket {
			send = send_socket,
			recv = recv_socket,
		}
		return udp_socket, true
	case:
		return Socket{}, false
	}
}


// Emulates the sending onto a network socket by pushing onto the packet queue.
// Returns the len of the byte buffer passed in 
send_interception :: proc(socket: ^Interception_Socket, buf: []byte) -> (int, bool) {

	// Copying here is necessary since the sending side will eventually free this memeory
	// so to be able to properly manage it on our interception side we need to copy it.
	copied_buf := make([]byte, len(buf))
	mem.copy(&copied_buf[0], &buf[0], len(buf))
	ok, err := queue.push_back(&socket.packet_queue, copied_buf)

	if err != nil {
		log.error("failed to push onto interception packet queue: ", err)
		return 0, false
	}

	return len(copied_buf), ok
}

// Take a packet from the packet queue and apply an effect on it.
process_interception_packet :: proc(socket: ^Interception_Socket) {

	// The incoming queue is assumed to be FIFO, to preserve the order that it
	// is written onto the queue, so we need to pop the front, since we're pushing
	// onto the back.
	packet_bytes, pop_ok := queue.pop_front_safe(&socket.packet_queue)
	if !pop_ok {
		log.info("incoming queue is empty")
		return
	}

	packet_reader := create_reader(convert_byte_slice_to_word_slice(packet_bytes))
	packet, packet_ok := deserialize_packet(&packet_reader, context.allocator)
	assert(packet_ok, "failed to deserialize packet")

	drop := rand.float32()
	if drop < socket.probabilities.drop {
		log.info("dropping packet")
		append(&socket.dropped_packets, packet_bytes)
	} else {
		push_ok, alloc_err := queue.push_back(&socket.outgoing_queue, packet_bytes)
		assert(push_ok, "failed to push onto the outgoing queue")
		assert(alloc_err == nil)
	}


	// For the drop effect we need to keep track of which packet / sequence that is dropped


	// For the lag effect, we need to store the packet in another buffer / queue until the lag effect is over
	// For the corruption we need to keep track of the original contents before corrupting
	// For duplicate we need to keep track of which packet / sequence the orignal was.

}

recv_interception :: proc(socket: ^Interception_Socket) -> ([]byte, bool) {

	//TODO(Thomas) Process the interception packet somewhere else??
	process_interception_packet(socket)

	packet, ok := queue.pop_front_safe(&socket.outgoing_queue)
	if !ok {
		log.info("incoming queue is empty")
		return nil, false
	}
	return packet, ok
}

drop_packet :: proc(socket: ^Interception_Socket) {}

lag_packet :: proc(socket: ^Interception_Socket) {}

corrupt_packet :: proc(socket: ^Interception_Socket) {}

duplicate_packet :: proc(socket: ^Interception_Socket) {}

send_socket_packet :: proc(
	socket: ^Socket,
	buf: []byte,
	endpoint: net.Endpoint,
) -> (
	bytes_written: int,
	err: Socket_Error,
) {
	switch &sock in socket^ {
	case UDP_Socket:
		return net.send_udp(sock.send, buf, endpoint)
	case Interception_Socket:
		bytes, ok := send_interception(&sock, buf)

		if !ok {
			return 0, Interception_Socket_Error{}
		}

		return bytes, nil
	case:
		return 0, nil
	}
}

recv_socket_packet :: proc(socket: ^Socket, buf: []byte) -> (int, net.Endpoint, Socket_Error) {
	switch &sock in socket^ {
	case UDP_Socket:
		bytes_read, remote_endpoint, err := net.recv_udp(sock.recv, buf[:])
		return bytes_read, remote_endpoint, err
	case Interception_Socket:
		recv_buf, ok := recv_interception(&sock)

		if !ok {
			// TODO(Thomas): The only "error" we can have here is that we don't have any packets
			// left on the queue. This is not an error though, it should be treated the same we do
			// with UDP_Recv_Error.Would_Block. We should just continue trying to consume the queue
			// until we finish.
			return 0, net.Endpoint{}, Interception_Socket_Error{}
		}

		assert(
			len(recv_buf) <= len(buf),
			"recv buffer is larger than the buffer we're copying bytes into",
		)
		mem.copy(&buf[0], &recv_buf[0], len(recv_buf))


		bytes_read := len(buf)
		remote_endpoint := net.Endpoint {
			address = net.IP4_Address{127, 0, 0, 1},
			port    = 8080,
		}
		err: net.Network_Error = nil
		return bytes_read, remote_endpoint, err
	case:
		return 0, net.Endpoint{}, nil
	}
}

// TODO(Thomas): Find a better place for this
Socket :: union {
	UDP_Socket,
	Interception_Socket,
}

Interception_Socket_Error :: enum {
	None = 0,
}

Socket_Error :: union #shared_nil {
	net.Network_Error,
	Interception_Socket_Error,
}

// TODO(Thomas): More finegrained handling here on the UDP socket side???
socket_close :: proc(socket: Socket) {
	switch sock in socket {
	case UDP_Socket:
		net.close(sock.send)
		net.close(sock.recv)
	case Interception_Socket:
	// We don't really do anything here.
	}
}
