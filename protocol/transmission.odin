package protocol

import "base:runtime"
import queue "core:container/queue"
import "core:mem"
import "core:net"

MAX_OUTGOING_PACKETS :: 8


Send_Stream :: struct {
	allocator:        runtime.Allocator,
	queue:            queue.Queue([]u8),
	socket:           net.UDP_Socket,
	current_sequence: u16,
}

create_send_stream :: proc(
	allocator: runtime.Allocator,
	address: string,
	port: int,
) -> Send_Stream {
	packet_queue := queue.Queue([]u8){}
	queue.init(&packet_queue, MAX_OUTGOING_PACKETS, allocator)

	address := net.parse_address(address)
	assert(address != nil)

	socket, bound_socket_err := net.make_bound_udp_socket(address, port)
	assert(bound_socket_err == nil)

	return Send_Stream {
		allocator = allocator,
		queue = packet_queue,
		socket = socket,
		current_sequence = 0,
	}
}


// client / server gives packet data
// process packet data -> split into one or more net packets
// send packets 

split_net_packet_into_fragments :: proc(packet_data: []u8, allocator: runtime.Allocator) {
	num_fragments := 0

	packet_size := u32(len(packet_data))

	remainder := packet_size % MAX_FRAGMENT_SIZE

	if remainder == 0 {
		num_fragments = int(packet_size) / MAX_FRAGMENT_SIZE
	} else {
		num_fragments = (int(packet_size) / MAX_FRAGMENT_SIZE) + 1
	}

	for i in 0 ..< num_fragments {

	}
}

enqueue_packet :: proc(send_stream: ^Send_Stream, packet: []u8) {
	assert(len(packet) > 0)
	assert(len(packet) < MAX_PACKET_SIZE)

	if len(packet) > MTU {
		// Larger than MTU, so we need to split it into fragments
		fragments := split_packet_into_fragments(
			send_stream.current_sequence,
			packet,
			send_stream.allocator,
		)

		for fragment in fragments {

		}

	} else {
		// The packet data is small enough to fit into a single network packet
	}
}
