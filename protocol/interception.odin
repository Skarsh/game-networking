package protocol

import queue "core:container/queue"
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
	incoming_queue:     queue.Queue([]u8),
	dropped_packets:    [dynamic][]u8,
	lagged_packets:     [dynamic][]Lagged_Packet,
	corrupted_packets:  [dynamic]Corrupted_Packet,
	duplicated_packets: [dynamic]Duplicated_Packet,
	outgoing_queue:     queue.Queue([]u8),
}

send_interception :: proc(socket: Interception_Socket, buf: []byte) -> int {
	// Take a incoming packet and apply an effect.
	// For the drop effect we need to keep track of which packet / sequence that is dropped
	// For the lag effect, we need to store the packet in another buffer / queue until the lag effect is over
	// For the corruption we need to keep track of the original contents before corrupting
	// For duplicate we need to keep track of which packet / sequence the orignal was.
	return 14
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
	err: net.Network_Error,
) {
	switch sock in socket {
	case net.UDP_Socket:
		return net.send_udp(sock, buf, endpoint)
	case Interception_Socket:
		bytes := send_interception(sock, buf)
		return bytes, nil
	}
	return 0, nil
}

// TODO(Thomas): Find a better place for this
Socket :: union {
	net.UDP_Socket,
	Interception_Socket,
}
