package main

import "core:fmt"
import "core:testing"

BitWriter :: struct {
	buffer:       []u32,
	scratch:      u64,
	scratch_bits: u32,
	word_index:   u32,
}

write_bits :: proc(writer: ^BitWriter, value: u32, bits: u32) -> bool {

	// NOTE(Thomas): 
	// Asserting for debugging, probably remove when stable
	assert(bits >= 0 && bits <= 32)

	if bits < 0 || bits > 32 {
		return false
	}

	if writer.word_index >= u32(len(writer.buffer)) {
		return false
	}

	// Example: 
	// value = 4
	// bits = 3
	// 0b0000_0001 << 3
	// 0b0000_1000
	// - 1
	// 0b0000_0111
	// Minus 1 to make all the bits below the leftshift to one
	// 0b0000_0100 & 0b0000_0111 == 0b0000_0100

	mask := u32(1 << bits) - 1
	masked_value := value & mask

	// Left shift to write the value in where its supposed to be
	writer.scratch |= u64(masked_value) << writer.scratch_bits
	writer.scratch_bits += bits

	// We've overflowed the scratch bits, time to flush the bits
	if writer.scratch_bits >= 32 {

		// Store the value of the scratch into the buffer. We AND (&) mask here with the lower 32-bits
		// To only write those lower 32 bits into the buffer at the word index 
		writer.buffer[writer.word_index] = u32(writer.scratch & 0xFF_FF_FF_FF)
		writer.word_index += 1
		writer.scratch >>= 32
		writer.scratch_bits -= 32
	}

	return true
}

create_writer :: proc(num_words: u32) -> BitWriter {
	buffer := make([]u32, num_words)
	bit_writer := BitWriter {
		buffer       = buffer,
		scratch      = 0,
		scratch_bits = 0,
		word_index   = 0,
	}
	return bit_writer
}

destroy_writer :: proc(writer: ^BitWriter) {
	delete(writer.buffer)
}

BitReader :: struct {
	buffer:        []u32,
	scratch:       u64,
	scratch_bits:  u32,
	total_bits:    u32,
	num_bits_read: u32,
	word_index:    u32,
}

create_reader :: proc(num_words: u32) -> BitReader {
	buffer := make([]u32, num_words)
	bit_reader := BitReader {
		buffer        = buffer,
		scratch       = 0,
		scratch_bits  = 0,
		total_bits    = num_words * 32,
		num_bits_read = 0,
		word_index    = 0,
	}
	return bit_reader
}

destroy_reader :: proc(reader: ^BitReader) {
	delete(reader.buffer)
}


read_bits :: proc(
	reader: ^BitReader,
	bits: u32,
) -> (
	value: u32,
	success: bool,
) {
	// NOTE(Thomas): 
	// Asserting for debugging, probably remove when stable
	assert(bits >= 0 && bits <= 32)

	if bits < 0 || bits > 32 {
		return 0, false
	}


	return 0, true
}

@(test)
test_write_zero_and_zero_bits :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

	res := write_bits(&writer, 0, 0)

	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.buffer[writer.word_index], 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_single_bit :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 1)
	testing.expect_value(t, writer.scratch_bits, 1)
}

@(test)
test_write_full_word :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

	res := write_bits(&writer, 0xFFFFFFFF, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFFFFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_across_word_boundary :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

	res := write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	res = write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFFFFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_multiple_words :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

	for i in 0 ..< 3 {
		res := write_bits(&writer, 0xFFFFFFFF, 32)
		testing.expect(t, res)
	}
	testing.expect_value(t, writer.word_index, 3)
	testing.expect_value(t, writer.buffer[0], 0xFFFFFFFF)
	testing.expect_value(t, writer.buffer[1], 0xFFFFFFFF)
	testing.expect_value(t, writer.buffer[2], 0xFFFFFFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_partial_bits :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

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
	writer := create_writer(100)
	defer destroy_writer(&writer)

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
	writer := create_writer(100)
	defer destroy_writer(&writer)

	res := write_bits(&writer, 0xFFFFFFFF, 0)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
}

@(test)
test_write_mixed_bit_lengths :: proc(t: ^testing.T) {
	writer := create_writer(100)
	defer destroy_writer(&writer)

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
