package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import proto "protocol"

main :: proc() {
	fmt.println("Hellope")

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		if len(track.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
			for entry in track.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	logger := log.create_console_logger(log.Level.Info)
	context.logger = logger
	defer log.destroy_console_logger(logger)

	recv_arena := virtual.Arena{}
	recv_arena_buffer := make([]u8, 100 * 1024)
	recv_arena_alloc_err := virtual.arena_init_buffer(&recv_arena, recv_arena_buffer)
	assert(recv_arena_alloc_err == .None)
	recv_arena_allocator := virtual.arena_allocator(&recv_arena)
	defer delete(recv_arena_buffer)

	recv_stream := proto.create_recv_stream(
		context.allocator,
		recv_arena_allocator,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_recv_stream(&recv_stream)

	send_arena := virtual.Arena{}
	send_arena_buffer := make([]u8, 100 * 1024)
	send_arena_alloc_err := virtual.arena_init_buffer(&send_arena, send_arena_buffer)
	assert(send_arena_alloc_err == .None)
	send_arena_allocator := virtual.arena_allocator(&send_arena)
	defer delete(send_arena_buffer)

	// TODO(Thomas): Pass in the Arena instead
	send_stream := proto.create_send_stream(
		send_arena_allocator,
		"127.0.0.1",
		8000,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_send_stream(&send_stream)


}
