package protocol

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:testing"


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
	position: Vector3,
	velocity: Vector3,
}

Test_Packet :: union {
	Test_Packet_A,
	Test_Packet_B,
	Test_Packet_C,
}


@(require_results)
serialize_test_packet_a :: proc(bit_writer: ^Bit_Writer, test_packet: Test_Packet_A) -> bool {
	if !serialize_integer(bit_writer, test_packet.a, math.min(i32), math.max(i32)) {
		log.error("failed to serialize field `a` of Test_Packet_A")
		return false
	}

	if !serialize_integer(bit_writer, test_packet.b, math.min(i32), math.max(i32)) {
		log.error("failed to serialize field `b` of Test_Packet_A")
		return false
	}

	if !serialize_integer(bit_writer, test_packet.c, math.min(i32), math.max(i32)) {
		log.error("failed to serialize field `c` of Test_Packet_A")
		return false
	}

	return true
}

@(require_results)
serialize_test_packet_b :: proc(bit_writer: ^Bit_Writer, test_packet: Test_Packet_B) -> bool {
	for item in test_packet.items {
		if !serialize_integer(bit_writer, item, math.min(i32), math.max(i32)) {
			log.error("failed to serialize item of Test_Packet_B")
			return false
		}
	}

	return true
}

@(require_results)
serialize_test_packet_c :: proc(bit_writer: ^Bit_Writer, test_packet: Test_Packet_C) -> bool {
	if !serialize_vector3(bit_writer, test_packet.position) {
		log.error("failed to serialize position of Test_Packet_C")
		return false
	}

	if !serialize_vector3(bit_writer, test_packet.velocity) {
		log.error("failed to serialize velocity of Test_Packet_C")
		return false
	}

	return true
}

@(require_results)
serialize_test_packet :: proc(bit_writer: ^Bit_Writer, test_packet: Test_Packet) -> bool {
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
deserialize_test_packet_a :: proc(bit_reader: ^Bit_Reader) -> (Test_Packet_A, bool) {
	a, a_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !a_ok {
		log.error("failed to deserialize field `a` of Test_Packet_A")
		return Test_Packet_A{}, false
	}

	b, b_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !b_ok {
		log.error("failed to deserialize field `b` of Test_Packet_A")
		return Test_Packet_A{}, false
	}

	c, c_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !c_ok {
		log.error("failed to deserialize field `c` of Test_Packet_A")
		return Test_Packet_A{}, false
	}

	return Test_Packet_A{a = a, b = b, c = c}, true
}

@(require_results)
deserialize_test_packet_b :: proc(bit_reader: ^Bit_Reader) -> (Test_Packet_B, bool) {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		item, ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
		if !ok {
			log.error("failed to deserialize item of Test_Packet_B")
			return Test_Packet_B{}, false
		}
		test_packet.items[i] = item
	}

	return test_packet, true
}

@(require_results)
deserialize_test_packet_c :: proc(bit_reader: ^Bit_Reader) -> (Test_Packet_C, bool) {
	position, position_ok := deserialize_vector3(bit_reader)
	if !position_ok {
		log.error("failed to deserialize position of Test_Packet_C")
		return Test_Packet_C{}, false
	}

	velocity, velocity_ok := deserialize_vector3(bit_reader)
	if !velocity_ok {
		log.error("failed to deserialize velocity of Test_Packet_C")
		return Test_Packet_C{}, false
	}

	return Test_Packet_C{position = position, velocity = velocity}, true
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

@(test)
test_serialize_deserialize_test_packet_a :: proc(t: ^testing.T) {

	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

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

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_a, des_test_packet_a_ok := deserialize_test_packet_a(&reader)

	testing.expectf(t, des_test_packet_a_ok, "deserialize_test_packet_a should be successful")

	testing.expect_value(t, des_test_packet_a, test_packet_a)
}

@(test)
test_serialize_deserialize_test_packet_b :: proc(t: ^testing.T) {
	buffer := make([]u32, 2048)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	test_packet_b := Test_Packet_B{}
	for &item in test_packet_b.items {
		item = 42
	}

	testing.expectf(
		t,
		serialize_test_packet_b(&writer, test_packet_b),
		"serialize_test_packet_b should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_b, des_test_packet_b_ok := deserialize_test_packet_b(&reader)

	testing.expectf(t, des_test_packet_b_ok, "deserialize_test_packet_b should be successful")

	testing.expect_value(t, des_test_packet_b, test_packet_b)
}

@(test)
test_serialize_deserialize_test_packet_c :: proc(t: ^testing.T) {

	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	test_packet_c := Test_Packet_C {
		position = Vector3{1.0, 2.0, 3.0},
		velocity = Vector3{4.0, 5.0, 6.0},
	}

	testing.expectf(
		t,
		serialize_test_packet_c(&writer, test_packet_c),
		"serialize_test_packet_c should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_test_packet_c, des_test_packet_c_ok := deserialize_test_packet_c(&reader)

	testing.expectf(t, des_test_packet_c_ok, "deserialize_test_packet_c should be successful")

	testing.expect_value(t, des_test_packet_c, test_packet_c)
}
