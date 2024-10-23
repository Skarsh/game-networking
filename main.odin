package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:testing"

import proto "protocol"

Test_Packet_Type :: enum {
	A,
	B,
	C,
}

Test_Packet_A :: struct {
	a: i32,
	b: i32,
	c: i32,
}

// This will be larger than MTU, so needs to be split into fragments
Test_Packet_B :: struct {
	items: [2048]i32,
}

Test_Packet_C :: struct {
	position: proto.Vector3,
	velocity: proto.Vector3,
}

Test_Packet :: union {
	Test_Packet_A,
	Test_Packet_B,
	Test_Packet_C,
}


@(require_results)
serialize_test_packet_a :: proc(
	bit_writer: ^proto.Bit_Writer,
	test_packet: Test_Packet_A,
) -> bool {
	proto.serialize_integer(bit_writer, test_packet.a, math.min(i32), math.max(i32)) or_return
	proto.serialize_integer(bit_writer, test_packet.b, math.min(i32), math.max(i32)) or_return
	proto.serialize_integer(bit_writer, test_packet.c, math.min(i32), math.max(i32)) or_return

	return true
}

@(require_results)
serialize_test_packet_b :: proc(
	bit_writer: ^proto.Bit_Writer,
	test_packet: Test_Packet_B,
) -> bool {
	for item in test_packet.items {
		proto.serialize_integer(bit_writer, item, math.min(i32), math.max(i32)) or_return
	}

	return true
}

@(require_results)
serialize_test_packet_c :: proc(
	bit_writer: ^proto.Bit_Writer,
	test_packet: Test_Packet_C,
) -> bool {
	proto.serialize_vector3(bit_writer, test_packet.position) or_return
	proto.serialize_vector3(bit_writer, test_packet.velocity) or_return

	return true
}

@(require_results)
serialize_test_packet :: proc(bit_writer: ^proto.Bit_Writer, test_packet: Test_Packet) -> bool {
	switch packet in test_packet {
	case Test_Packet_A:
		serialize_test_packet_a(bit_writer, packet) or_return
	case Test_Packet_B:
		serialize_test_packet_b(bit_writer, packet) or_return
	case Test_Packet_C:
		serialize_test_packet_c(bit_writer, packet) or_return
	}

	return true
}


@(require_results)
deserialize_test_packet_a :: proc(bit_reader: ^proto.Bit_Reader) -> (Test_Packet_A, bool) {
	a, a_ok := proto.deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !a_ok {
		return Test_Packet_A{}, false
	}

	b, b_ok := proto.deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !b_ok {
		return Test_Packet_A{}, false
	}

	c, c_ok := proto.deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !c_ok {
		return Test_Packet_A{}, false
	}

	return Test_Packet_A{a = a, b = b, c = c}, true
}

@(require_results)
deserialize_test_packet_b :: proc(bit_reader: ^proto.Bit_Reader) -> (Test_Packet_B, bool) {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		item, ok := proto.deserialize_integer(bit_reader, math.min(i32), math.max(i32))
		if !ok {
			return Test_Packet_B{}, false
		}
		test_packet.items[i] = item
	}

	return test_packet, true
}

@(require_results)
deserialize_test_packet_c :: proc(bit_reader: ^proto.Bit_Reader) -> (Test_Packet_C, bool) {
	position, position_ok := proto.deserialize_vector3(bit_reader)
	if !position_ok {
		return Test_Packet_C{}, false
	}

	velocity, velocity_ok := proto.deserialize_vector3(bit_reader)
	if !velocity_ok {

		return Test_Packet_C{}, false
	}

	return Test_Packet_C{position = position, velocity = velocity}, true
}

// ------------- Utility procedures -------------

// TODO(Thomas): This is duplicated from the serialization long running tests
// should group all these utility procedures somewhere
random_vector3 :: proc(lo: f32, hi: f32) -> proto.Vector3 {
	return proto.Vector3 {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

random_test_packet_a :: proc() -> Test_Packet_A {
	a := rand.int31()
	b := rand.int31()
	c := rand.int31()
	return Test_Packet_A{a = a, b = b, c = c}
}

random_test_packet_b :: proc() -> Test_Packet_B {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		test_packet.items[i] = rand.int31()
	}
	return test_packet
}

random_test_packet_c :: proc(lo: f32, hi: f32) -> Test_Packet_C {
	position := random_vector3(lo, hi)
	velocity := random_vector3(lo, hi)
	return Test_Packet_C{position = position, velocity = velocity}
}

random_test_packet :: proc(lo: f32, hi: f32) -> Test_Packet {
	info := type_info_of(Test_Packet)
	variants_len := 0

	#partial switch v in info.variant {
	case runtime.Type_Info_Named:
		#partial switch vv in v.base.variant {
		case runtime.Type_Info_Union:
			variants_len = len(vv.variants)
		case:
			unreachable()
		}
	case:
		unreachable()
	}

	random := rand.int_max(variants_len)
	switch random {
	case 0:
		return random_test_packet_a()
	case 1:
		return random_test_packet_b()
	case 2:
		return random_test_packet_c(lo, hi)
	case:
		unreachable()
	}
}

main :: proc() {

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

	// TODO(Thomas): Make own allocators here.
	recv_stream := proto.create_recv_stream(
		context.allocator,
		context.temp_allocator,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_recv_stream(&recv_stream)

	// TODO(Thomas): Make own allocator here, Arena based probably
	send_stream := proto.create_send_stream(
		context.temp_allocator,
		"127.0.0.1",
		8000,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_send_stream(&send_stream)

	// TODO(Thomas): Split more of this functionality out
	for {
		test_packet := random_test_packet(-1000, 1000)

		test_packet_buffer: []u32

		test_packet_type_ser := Test_Packet_Type.A
		switch ty in test_packet {
		case Test_Packet_A:
			test_packet_type_ser = .A
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		case Test_Packet_B:
			test_packet_type_ser = .B
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		case Test_Packet_C:
			test_packet_type_ser = .C
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		}

		log.info("Send test packet type", test_packet_type_ser)
		log.info("Send test packet type (u32):", u32(test_packet_type_ser))

		defer delete(test_packet_buffer)

		test_packet_writer := proto.create_writer(test_packet_buffer)

		serialize_test_packet_ok := serialize_test_packet(&test_packet_writer, test_packet)
		assert(serialize_test_packet_ok)

		flush_bits_ok := proto.flush_bits(&test_packet_writer)


		proto.enqueue_packet(
			&send_stream,
			proto.QOS.Best_Effort,
			u32(test_packet_type_ser),
			proto.convert_word_slice_to_byte_slice(test_packet_writer.buffer),
		)

		proto.process_send_stream(&send_stream)

		for proto.recv_packet(&recv_stream) {}

		packet_data, packet_data_ok := proto.process_recv_stream(&recv_stream, context.allocator)

		assert(packet_data_ok)
		defer delete(packet_data.data, context.allocator)

		test_packet_type_des := Test_Packet_Type(packet_data.type)

		log.info("Recv test packet_type: ", test_packet_type_des)

		test_packet_reader := proto.create_reader(
			proto.convert_byte_slice_to_word_slice(packet_data.data),
		)

		des_test_packet: Test_Packet
		des_test_packet_ok := false
		switch test_packet_type_des {
		case .A:
			des_test_packet, des_test_packet_ok = deserialize_test_packet_a(&test_packet_reader)
			assert(des_test_packet_ok)
		case .B:
			des_test_packet, des_test_packet_ok = deserialize_test_packet_b(&test_packet_reader)
			assert(des_test_packet_ok)
		case .C:
			des_test_packet, des_test_packet_ok = deserialize_test_packet_c(&test_packet_reader)
			assert(des_test_packet_ok)
		}


		assert(des_test_packet == test_packet)
	}
}

@(test)
test_serialize_deserialize_test_packet_a :: proc(t: ^testing.T) {

	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := proto.create_writer(buffer)
	reader := proto.create_reader(buffer)

	test_packet_a := Test_Packet_A {
		a = 1,
		b = 2,
		c = 3,
	}

	testing.expectf(
		t,
		serialize_test_packet_a(&writer, test_packet_a),
		"serialize_test_packet_a should be successful",
	)

	testing.expectf(t, proto.flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_a, des_test_packet_a_ok := deserialize_test_packet_a(&reader)

	testing.expectf(t, des_test_packet_a_ok, "deserialize_test_packet_a should be successful")

	testing.expect_value(t, des_test_packet_a, test_packet_a)
}

@(test)
test_serialize_deserialize_test_packet_b :: proc(t: ^testing.T) {
	buffer := make([]u32, 2048)
	defer delete(buffer)
	writer := proto.create_writer(buffer)
	reader := proto.create_reader(buffer)

	test_packet_b := Test_Packet_B{}
	for &item in test_packet_b.items {
		item = 42
	}

	testing.expectf(
		t,
		serialize_test_packet_b(&writer, test_packet_b),
		"serialize_test_packet_b should be successful",
	)

	testing.expectf(t, proto.flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_b, des_test_packet_b_ok := deserialize_test_packet_b(&reader)

	testing.expectf(t, des_test_packet_b_ok, "deserialize_test_packet_b should be successful")

	testing.expect_value(t, des_test_packet_b, test_packet_b)
}

@(test)
test_serialize_deserialize_test_packet_c :: proc(t: ^testing.T) {

	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := proto.create_writer(buffer)
	reader := proto.create_reader(buffer)

	test_packet_c := Test_Packet_C {
		position = proto.Vector3{1.0, 2.0, 3.0},
		velocity = proto.Vector3{4.0, 5.0, 6.0},
	}

	testing.expectf(
		t,
		serialize_test_packet_c(&writer, test_packet_c),
		"serialize_test_packet_c should be successful",
	)

	testing.expectf(t, proto.flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_c, des_test_packet_c_ok := deserialize_test_packet_c(&reader)

	testing.expectf(t, des_test_packet_c_ok, "deserialize_test_packet_c should be successful")

	testing.expect_value(t, des_test_packet_c, test_packet_c)
}
