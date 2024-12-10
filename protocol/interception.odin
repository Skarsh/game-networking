package protocol

import queue "core:container/queue"
import "core:log"
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

Lagged_Packet :: struct {
	data: []u8,
	// This is the number of packets that needs to be sent before this is sent.
	// This makes it easier for now, arguably time is more realistic, but that would
	// comes with a lot of issues too.
	lag:  int,
}

Corrupted_Packet :: struct {
	original: []u8,
	mutated:  []u8,
}

Duplicated_Packet :: struct {
	data:         []u8,
	original_seq: u16,
	duplicated:   u16,
}

Interception_Socket :: struct {
	packet_queue:       queue.Queue([]u8),
	dropped_packets:    [dynamic][]u8,
	lagged_packets:     [dynamic][]Lagged_Packet,
	corrupted_packets:  [dynamic]Corrupted_Packet,
	duplicated_packets: [dynamic]Duplicated_Packet,
	outgoing_queue:     queue.Queue([]u8),
}

// Emulates the sending onto a network socket by pushing onto the packet queue.
// Returns the len of the byte buffer passed in 
send_interception :: proc(socket: ^Interception_Socket, buf: []byte) -> (int, bool) {
	ok, err := queue.push_back(&socket.packet_queue, buf)

	if err != nil {
		log.error("failed to push onto interception packet queue: ", err)
		return 0, false
	}

	return len(buf), ok
}

// Take a packet from the packet queue and apply an effect on it.
process_interception_packet :: proc(socket: ^Interception_Socket) {

	// The incoming queue is assumed to be FIFO, to preserve the order that it
	// is written onto the queue, so we need to pop the front, since we're pushing
	// onto the back.
	item, ok := queue.pop_front_safe(&socket.packet_queue)
	if !ok {
		log.info("incoming queue is empty")
		return
	}

	// For the drop effect we need to keep track of which packet / sequence that is dropped


	// For the lag effect, we need to store the packet in another buffer / queue until the lag effect is over
	// For the corruption we need to keep track of the original contents before corrupting
	// For duplicate we need to keep track of which packet / sequence the orignal was.

}


drop_packet :: proc(socket: ^Interception_Socket) {}

lag_packet :: proc(socket: ^Interception_Socket) {}

corrupt_packet :: proc(socket: ^Interception_Socket) {}

duplicate_packet :: proc(socket: ^Interception_Socket) {}

send_packet :: proc(
	socket: Socket,
	buf: []byte,
	endpoint: net.Endpoint,
) -> (
	bytes_written: int,
	err: Socket_Error,
) {
	switch &sock in socket {
	case net.UDP_Socket:
		return net.send_udp(sock, buf, endpoint)
	case Interception_Socket:
		bytes, ok := send_interception(&sock, buf)

		// We return a UDP_Send_Error here to try to mimic the real counterpart
		if !ok {
			return 0, Interception_Socket_Error{}
		}

		return bytes, nil
	case:
		return 0, nil
	}
}

// TODO(Thomas): Find a better place for this
Socket :: union {
	net.UDP_Socket,
	Interception_Socket,
}

Interception_Socket_Error :: struct {}

Socket_Error :: union {
	net.Network_Error,
	Interception_Socket_Error,
}
