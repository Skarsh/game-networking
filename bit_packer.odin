package main

import "core:fmt"
import "core:testing"

BitWriter :: struct {
	buffer:       []u32,
	scratch:      u64,
	scratch_bits: u32,
	word_index:   u32,
	max_bits:     u32,
}

create_writer :: proc(buffer: []u32) -> BitWriter {
	bit_writer := BitWriter {
		buffer       = buffer,
		scratch      = 0,
		scratch_bits = 0,
		word_index   = 0,
		max_bits     = u32(len(buffer) * 32),
	}
	return bit_writer
}

// Write the (n = bits) lowest bits from value to the buffer
write_bits :: proc(writer: ^BitWriter, value: u32, bits: u32) -> bool {

	// NOTE(Thomas): 
	// Asserting for debugging, probably remove when stable
	assert(
		bits >= 0 && bits <= 32,
		fmt.tprintf("Bits assumed to be 0 <= bits <= 32, but got %d", bits),
	)

	if bits == 0 {
		return true
	}

	if bits < 0 || bits > 32 {
		return false
	}

	// Check if writing these bits would exceed max_bits
	if writer.word_index * 32 + writer.scratch_bits + bits > writer.max_bits {
		return false
	}

	// Example: 
	// value = 4
	// bits = 3
	// 0b0000_0001 << 3
	// 0b0000_1000
	// - 1
	// 0b0000_0111
	// (Minus 1 to make all the bits below the leftshift to one)
	// 0b0000_0100 & 0b0000_0111 == 0b0000_0100

	mask := u32(1 << bits) - 1
	masked_value := value & mask

	// Left shift to write the value in where its supposed to be
	writer.scratch |= u64(masked_value) << writer.scratch_bits
	writer.scratch_bits += bits

	// We've overflowed the scratch bits, time to flush the bits
	if writer.scratch_bits >= 32 {

		// Store the value of the scratch into the buffer. We AND (&) mask here with the lower 32-bits
		// so that we only write those lower 32 bits into the buffer at the word index 
		writer.buffer[writer.word_index] = u32(writer.scratch & 0xFF_FF_FF_FF)
		writer.word_index += 1
		writer.scratch >>= 32
		writer.scratch_bits -= 32
	}

	return true
}

// Write the remaining bits to memory
final_flush_to_memory :: proc(writer: ^BitWriter) -> bool {

	if writer.word_index * 32 + writer.scratch_bits > writer.max_bits {
		return false
	}

	if writer.scratch_bits > 0 {
		writer.buffer[writer.word_index] = u32(writer.scratch & 0xFF_FF_FF_FF)
		writer.word_index += 1
	}

	writer.scratch = 0
	writer.scratch_bits = 0
	return true
}

BitReader :: struct {
	buffer:        []u32,
	scratch:       u64,
	scratch_bits:  u32,
	total_bits:    u32,
	num_bits_read: u32,
	word_index:    u32,
}

create_reader :: proc(buffer: []u32) -> BitReader {
	bit_reader := BitReader {
		buffer        = buffer,
		scratch       = 0,
		scratch_bits  = 0,
		total_bits    = u32(len(buffer) * 32),
		num_bits_read = 0,
		word_index    = 0,
	}
	return bit_reader
}

read_bits :: proc(
	reader: ^BitReader,
	bits: u32,
) -> (
	value: u32,
	success: bool,
) {
	if bits == 0 {
		return 0, true
	}

	if bits < 0 || bits > 32 {
		return 0, false
	}

	if bits > 32 || reader.num_bits_read + bits > reader.total_bits {
		return 0, false
	}

	if reader.word_index > u32(len(reader.buffer)) {
		return 0, false
	}

	// Ensure we have enough bits in the scratch
	if reader.scratch_bits < bits {
		// Read in a new word if we've exhausted the current one
		reader.scratch |=
			u64(reader.buffer[reader.word_index]) << reader.scratch_bits
		reader.scratch_bits += 32
		reader.word_index += 1
	}

	// Read the bits
	mask := u64((1 << bits) - 1)
	value = u32(reader.scratch & mask)

	// Update the scratch
	reader.scratch >>= bits
	reader.scratch_bits -= bits
	reader.num_bits_read += bits

	return value, true
}

@(test)
test_write_zero_and_zero_bits :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0, 0)

	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.buffer[writer.word_index], 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_single_bit :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 1)
	testing.expect_value(t, writer.scratch_bits, 1)
}

@(test)
test_write_full_word :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_across_word_boundary :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	res = write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_multiple_words :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	for i in 0 ..< 3 {
		res := write_bits(&writer, 0xFFFF_FFFF, 32)
		testing.expect(t, res)
	}
	testing.expect_value(t, writer.word_index, 3)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.buffer[1], 0xFFFF_FFFF)
	testing.expect_value(t, writer.buffer[2], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_partial_bits :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0b101, 3)
	testing.expect(t, res)
	res = write_bits(&writer, 0b11111, 5)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0b11111101)
	testing.expect_value(t, writer.scratch_bits, 8)
}

@(test)
test_overflow_protection :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	for i in 0 ..< len(writer.buffer) {
		res := write_bits(&writer, 0xFFFFFFFF, 32)
		testing.expect(t, res)
	}

	// This should fail as the buffer is full
	res := write_bits(&writer, 1, 1)
	testing.expect(
		t,
		!res,
		fmt.tprintf(
			"Expected write_bits result to be %v, but was %v",
			false,
			res,
		),
	)
}

@(test)
test_write_zero_bits :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 0)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_mixed_bit_lengths :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0b1, 1)
	testing.expect(t, res)
	res = write_bits(&writer, 0b1010, 4)
	testing.expect(t, res)
	res = write_bits(&writer, 0b11111111, 8)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0b11111111_1010_1)
	testing.expect_value(t, writer.scratch_bits, 13)
}

@(test)
test_write_flush :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	res = write_bits(&writer, 0b1101, 4)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[writer.word_index], 0)
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[1], 0b1101)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.word_index, 2)
}

@(test)
test_write_flush_on_last_word :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	for i in 0 ..< 99 {
		res := write_bits(&writer, 0xFFFF_FFFF, 32)
		testing.expect(t, res)
	}
	testing.expect_value(t, writer.word_index, 99)
	write_bits(&writer, 0x0000_0003, 3)
	success := final_flush_to_memory(&writer)
	testing.expect(t, success)
	testing.expect_value(t, writer.buffer[99], 0x0000_0003)
	testing.expect_value(t, writer.word_index, 100)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)

	res := write_bits(&writer, 0x0000_0001, 1)
	testing.expect(t, !res)
}

@(test)
test_read_zero_bits :: proc(t: ^testing.T) {
	buffer := []u32{0xFFFF_FFFF}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 0)
	testing.expect(t, success)
	testing.expect_value(t, value, 0)
	testing.expect_value(t, reader.num_bits_read, 0)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_single_bit :: proc(t: ^testing.T) {
	buffer := []u32{0x0000_0001}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 1)
	testing.expect(t, success)
	testing.expect_value(t, value, 1)
	testing.expect_value(t, reader.num_bits_read, 1)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 31)
}

@(test)
test_read_full_word :: proc(t: ^testing.T) {
	buffer := []u32{0xFFFF_FFFF}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 32)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xFFFF_FFFF)
	testing.expect_value(t, reader.num_bits_read, 32)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_across_word_boundary :: proc(t: ^testing.T) {
	buffer := []u32{0xFFFF_0000, 0x0000_FFFF}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 16)
	testing.expect(t, success)
	testing.expect_value(t, value, 0x0000)
	testing.expect_value(t, reader.scratch, 0x0000_FFFF)
	testing.expect_value(t, reader.scratch_bits, 16)

	value, success = read_bits(&reader, 16)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xFFFF)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)

	value, success = read_bits(&reader, 16)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xFFFF)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 16)

	testing.expect_value(t, reader.num_bits_read, 48)
}

@(test)
test_read_partial_bits :: proc(t: ^testing.T) {
	buffer := []u32{0b11111101}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 3)
	testing.expect(t, success)
	testing.expect_value(t, value, 0b101)
	testing.expect_value(t, reader.scratch, 0b11111)
	testing.expect_value(t, reader.scratch_bits, 29)

	value, success = read_bits(&reader, 5)
	testing.expect(t, success)
	testing.expect_value(t, value, 0b11111)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 24)

	testing.expect_value(t, reader.num_bits_read, 8)
}

@(test)
test_read_overflow_protection :: proc(t: ^testing.T) {
	buffer := []u32{0xFFFF_FFFF}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 32)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xFFFF_FFFF)

	// This should fail as we've read all available bits
	value, success = read_bits(&reader, 1)
	testing.expect(t, !success)
	testing.expect_value(t, reader.num_bits_read, 32)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_mixed_bit_lengths :: proc(t: ^testing.T) {
	buffer := []u32{0b11111111_1010_1}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 1)
	testing.expect(t, success)
	testing.expect_value(t, value, 0b1)
	testing.expect_value(t, reader.scratch, 0b11111111_1010)
	testing.expect_value(t, reader.scratch_bits, 31)

	value, success = read_bits(&reader, 4)
	testing.expect(t, success)
	testing.expect_value(t, value, 0b1010)
	testing.expect_value(t, reader.scratch, 0b11111111)
	testing.expect_value(t, reader.scratch_bits, 27)

	value, success = read_bits(&reader, 8)
	testing.expect(t, success)
	testing.expect_value(t, value, 0b11111111)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 19)

	testing.expect_value(t, reader.num_bits_read, 13)
}

@(test)
test_read_exact_buffer_size :: proc(t: ^testing.T) {
	buffer := []u32{0xAAAA_AAAA, 0xBBBB_BBBB}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 32)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xAAAA_AAAA)

	value, success = read_bits(&reader, 32)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xBBBB_BBBB)

	value, success = read_bits(&reader, 1)
	testing.expect(t, !success)
	testing.expect_value(t, reader.num_bits_read, 64)
}

@(test)
test_read_large_bit_count :: proc(t: ^testing.T) {
	buffer := []u32{0xAAAA_AAAA, 0xBBBB_BBBB}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 33)
	testing.expect(t, !success)
	testing.expect_value(t, reader.num_bits_read, 0)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_empty_buffer :: proc(t: ^testing.T) {
	buffer := []u32{}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 1)
	testing.expect(t, !success)
	testing.expect_value(t, reader.num_bits_read, 0)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_multiple_small_reads :: proc(t: ^testing.T) {
	buffer := []u32{0xF0F0_F0F0}
	reader := create_reader(buffer[:])

	for i in 0 ..< 8 {
		value, success := read_bits(&reader, 4)
		testing.expect(t, success)
		testing.expect_value(t, value, 0x0 if i % 2 == 0 else 0xF)
	}

	testing.expect_value(t, reader.num_bits_read, 32)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_bits_after_full_read :: proc(t: ^testing.T) {
	buffer := []u32{0xAAAA_AAAA}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 32)
	testing.expect(t, success)
	testing.expect_value(t, value, 0xAAAA_AAAA)

	// Try to read more bits after fully reading the buffer
	value, success = read_bits(&reader, 1)
	testing.expect(t, !success)
	testing.expect_value(t, reader.num_bits_read, 32)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_write_then_read_simple :: proc(t: ^testing.T) {
	buffer := make([]u32, 2)
	defer delete(buffer)

	writer := create_writer(buffer)
	success := write_bits(&writer, 0b1010, 4)
	testing.expect(t, success)
	success = write_bits(&writer, 0b11110000, 8)
	testing.expect(t, success)
	success = final_flush_to_memory(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 4)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0b1010)

	value, read_success = read_bits(&reader, 8)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0b11110000)
}

@(test)
test_write_then_read_full_word :: proc(t: ^testing.T) {
	buffer := make([]u32, 1)
	defer delete(buffer)

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xAABB_CCDD, 32)
	testing.expect(t, success)
	success = final_flush_to_memory(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xAABB_CCDD)
}

@(test)
test_write_then_read_across_word_boundary :: proc(t: ^testing.T) {
	buffer := make([]u32, 2)
	defer delete(buffer)

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, success)
	success = write_bits(&writer, 0xAAAA, 16)
	testing.expect(t, success)
	success = write_bits(&writer, 0xBBBB, 16)
	testing.expect(t, success)
	success = final_flush_to_memory(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 16)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xFFFF)

	value, read_success = read_bits(&reader, 16)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xAAAA)

	value, read_success = read_bits(&reader, 16)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xBBBB)
}

@(test)
test_write_then_read_mixed_bit_lengths :: proc(t: ^testing.T) {
	buffer := make([]u32, 2)
	defer delete(buffer)

	writer := create_writer(buffer)
	success := write_bits(&writer, 0b1, 1)
	testing.expect(t, success)
	success = write_bits(&writer, 0b1010, 4)
	testing.expect(t, success)
	success = write_bits(&writer, 0xFF, 8)
	testing.expect(t, success)
	success = write_bits(&writer, 0xABCD, 16)
	testing.expect(t, success)
	success = final_flush_to_memory(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 1)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0b1)

	value, read_success = read_bits(&reader, 4)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0b1010)

	value, read_success = read_bits(&reader, 8)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xFF)

	value, read_success = read_bits(&reader, 16)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xABCD)
}

@(test)
test_write_then_read_full_buffer :: proc(t: ^testing.T) {
	buffer := make([]u32, 2)
	defer delete(buffer)

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, success)
	success = write_bits(&writer, 0xAAAA_AAAA, 32)
	testing.expect(t, success)
	success = final_flush_to_memory(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xFFFF_FFFF)

	value, read_success = read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xAAAA_AAAA)

	// Try to read one more bit, which should fail
	_, read_success = read_bits(&reader, 1)
	testing.expect(t, !read_success)
}
