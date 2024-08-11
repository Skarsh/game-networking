package main

import "core:math"
import "core:testing"

PacketA :: struct {
	x, y, z: u32,
}

write_packet_a :: proc(buffer: ^Buffer, packet: PacketA) {
	write_u32(buffer, packet.x)
	write_u32(buffer, packet.y)
	write_u32(buffer, packet.z)
}

read_packet_a :: proc(buffer: ^Buffer) -> PacketA {
	packet_a := PacketA{}
	packet_a.z = read_u32(buffer)
	packet_a.y = read_u32(buffer)
	packet_a.x = read_u32(buffer)
	return packet_a
}

Buffer :: struct {
	data:  []u8,
	index: uint,
}

// TODO(Thomas): What about endianness?
write_u32 :: proc(buffer: ^Buffer, value: u32) {
	assert(buffer.index + size_of(value) <= uint(len(buffer.data)))

	(^u32)(&buffer.data[buffer.index])^ = value
	buffer.index += size_of(value)
}

// TODO(Thomas): What about endianness?
read_u32 :: proc(buffer: ^Buffer) -> u32 {
	value_size: uint = size_of(u32)
	assert(buffer.index - value_size >= 0)
	value := parse_u32_from_bytes(
		buffer.data[buffer.index - value_size:buffer.index],
	)
	buffer.index -= value_size
	return value
}

// TODO(Thomas): What about endianness?
write_i32 :: proc(buffer: ^Buffer, value: i32) {
	assert(buffer.index + size_of(value) <= uint(len(buffer.data)))

	(^i32)(&buffer.data[buffer.index])^ = value
	buffer.index += size_of(value)
}

read_i32 :: proc(buffer: ^Buffer) -> i32 {
	value_size: uint = size_of(i32)
	assert(buffer.index - value_size >= 0)
	value := parse_i32_from_bytes(
		buffer.data[buffer.index - value_size:buffer.index],
	)
	buffer.index -= value_size
	return value
}


@(test)
test_write_u32 :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	val := parse_u32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, 0)

	write_u32(&buf, 42)
	val = parse_u32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, 42)
}

@(test)
test_read_u32 :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	write_u32(&buf, 14)
	val := read_u32(&buf)
	testing.expect_value(t, val, 14)
}

@(test)
test_write_i32 :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	val := parse_i32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, 0)

	write_i32(&buf, -42)
	val = parse_i32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, -42)
}

@(test)
test_read_i32 :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	write_i32(&buf, -14)
	val := read_i32(&buf)
	testing.expect_value(t, val, -14)
}

@(test)
test_write_packet_a :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	val := parse_u32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, 0)

	packet_a := PacketA {
		x = 1,
		y = 2,
		z = 3,
	}

	write_packet_a(&buf, packet_a)

	val = parse_u32_from_bytes(buf.data[0:4])
	testing.expect_value(t, val, 1)

	val = parse_u32_from_bytes(buf.data[4:8])
	testing.expect_value(t, val, 2)

	val = parse_u32_from_bytes(buf.data[8:12])
	testing.expect_value(t, val, 3)
}

@(test)
test_read_packet_a :: proc(t: ^testing.T) {
	data := [100]u8{}
	buf := Buffer {
		data  = data[:],
		index = 0,
	}

	packet_write := PacketA {
		x = 1,
		y = 2,
		z = 3,
	}

	write_packet_a(&buf, packet_write)

	packet_read := read_packet_a(&buf)

	testing.expect_value(t, packet_write, packet_read)
}


@(private)
parse_u32_from_bytes :: proc(buf: []byte) -> u32 {
	assert(len(buf) >= size_of(u32))
	val := cast(^u32)(&buf[0])
	return val^
}

@(test)
test_parse_u32_from_bytes_all_zero_bytes :: proc(t: ^testing.T) {
	buf := []byte{0, 0, 0, 0}
	val := parse_u32_from_bytes(buf[:])
	testing.expect_value(t, val, 0)
}

@(test)
test_parse_u32_from_bytes_all_bytes_255 :: proc(t: ^testing.T) {
	buf := []byte{255, 255, 255, 255}
	val := parse_u32_from_bytes(buf[:])
	testing.expect_value(t, val, math.max(u32))
}

@(test)
test_parse_u32_from_bytes_first_byte_72 :: proc(t: ^testing.T) {
	buf := []byte{72, 0, 0, 0}
	val := parse_u32_from_bytes(buf[:])
	testing.expect_value(t, val, 72)
}

@(private)
parse_i32_from_bytes :: proc(buf: []byte) -> i32 {
	assert(len(buf) >= size_of(i32))
	val := cast(^i32)(&buf[0])
	return val^
}

@(test)
test_parse_i32_from_bytes_all_zero_bytes :: proc(t: ^testing.T) {
	buf := []byte{0, 0, 0, 0}
	val := parse_i32_from_bytes(buf[:])
	testing.expect_value(t, val, 0)
}

@(test)
test_parse_i32_from_negative_least_byte_max :: proc(t: ^testing.T) {
	buf := []byte{0, 0, 0, 255}
	i32 := parse_i32_from_bytes(buf[:])
	testing.expect_value(t, i32, -16_777_216)
}

@(test)
test_parse_i32_from_negative_max :: proc(t: ^testing.T) {
	buf := []byte{0, 0, 0, 0b_10000000}
	val := parse_i32_from_bytes(buf[:])
	testing.expect_value(t, val, math.min(i32))
}

@(test)
test_parse_i32_from_positive_max :: proc(t: ^testing.T) {
	buf := []byte{255, 255, 255, 0b0111_1111}
	val := parse_i32_from_bytes(buf[:])
	testing.expect_value(t, val, math.max(i32))
}
