package main

import "core:fmt"
import "core:mem"
import "core:testing"

Bit_Writer :: struct {
	buffer:       []u32,
	scratch:      u64,
	scratch_bits: u32,
	word_index:   u32,
	num_bits:     u32,
	bits_written: u32,
}

create_writer :: proc(buffer: []u32) -> Bit_Writer {
	bit_writer := Bit_Writer {
		buffer       = buffer,
		scratch      = 0,
		scratch_bits = 0,
		word_index   = 0,
		num_bits     = u32(len(buffer) * 32),
		bits_written = 0,
	}
	return bit_writer
}

// Write the (n = bits) lowest bits from value to the buffer
@(require_results)
write_bits :: proc(writer: ^Bit_Writer, value: u32, bits: u32) -> bool {

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
	if writer.word_index * 32 + writer.scratch_bits + bits > writer.num_bits {
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
	writer.bits_written += bits

	// We've overflowed the scratch bits, time to flush the bits
	if writer.scratch_bits >= 32 {

		// Store the value of the scratch into the buffer. We AND (&) mask here with the lower 32-bits
		// so that we only write those lower 32 bits into the buffer at the word index 
		writer.buffer[writer.word_index] = u32(writer.scratch & 0xFFFF_FFFF)
		writer.word_index += 1
		writer.scratch >>= 32
		writer.scratch_bits -= 32
	}

	return true
}

// Write the remaining bits in the scratch to the buffer.
// Resets scratch and scratch_bits.
@(require_results)
flush_bits :: proc(writer: ^Bit_Writer) -> bool {

	// If we have surpassed the max amounts that can possibly be written
	// to the writer we return false.
	if writer.word_index * 32 + writer.scratch_bits > writer.num_bits {
		return false
	}

	if writer.scratch_bits > 0 {
		writer.buffer[writer.word_index] = u32(writer.scratch & 0xFFFF_FFFF)
		writer.word_index += 1
	}

	writer.scratch = 0
	writer.scratch_bits = 0
	return true
}

// Write remaining bytes until byte aligned boundary
// One thing to note is that the writer.bits_written will now be increased
// up until the next byte boundary, even if this returns false.
@(require_results)
write_align :: proc(writer: ^Bit_Writer) -> bool {
	remainder_bits := writer.bits_written % 8
	if remainder_bits != 0 {
		success := write_bits(writer, 0, 8 - remainder_bits)
		assert((writer.bits_written % 8) == 0)
		return success
	}
	return true
}


@(require_results)
write_bytes :: proc(writer: ^Bit_Writer, data: []u8) -> bool {
	bytes := u32(len(data))

	assert(get_align_bits(writer.bits_written) == 0)
	target_bits_to_write := writer.bits_written + (bytes * 8)
	assert(target_bits_to_write <= writer.num_bits)

	head_bytes := calculate_head_bytes(writer.bits_written)
	if head_bytes > bytes {
		head_bytes = bytes
	}

	// Write all the head bytes (bytes necessary to reach the next word (32 bits / 4 byte) boundary)
	for i in 0 ..< head_bytes {
		if !write_bits(writer, u32(data[i]), 8) {
			// TODO(Thomas): Flipping this is not caught in any tests
			return false
		}
	}

	// If head_bytes is equal to the bytes, that means that the next word boundary 
	// is also the end of all we have to write. So we return success true here.
	// NOTE: It's not necessary to flush before returning because we've written
	// all the data we should, and we're word aligned.
	if head_bytes == bytes {
		return true
	}

	if !flush_bits(writer) {
		// TODO(Thomas): Fliiping this is not caught in tests
		return false
	}

	assert(get_align_bits(writer.bits_written) == 0)

	num_words := (bytes - head_bytes) / 4
	if num_words > 0 {
		assert(writer.bits_written % 32 == 0)
		copy_len := int(num_words) * 4
		mem.copy(
			&writer.buffer[writer.word_index],
			&data[head_bytes],
			copy_len,
		)
		writer.bits_written += num_words * 32
		writer.word_index += num_words
		writer.scratch = 0
	}

	assert(get_align_bits(writer.bits_written) == 0)
	tail_start := head_bytes + (num_words * 4)
	tail_bytes := bytes - tail_start
	assert(tail_bytes >= 0 && tail_bytes < 4)
	for i in 0 ..< tail_bytes {
		if !write_bits(writer, u32(data[tail_start + i]), 8) {
			return false
		}
	}

	assert(get_align_bits(writer.bits_written) == 0)
	assert(head_bytes + (num_words * 4) + tail_bytes == bytes)

	return true
}

// Get the number of bits until byte aligment
// E.g (8 - (5 % 8)) % 8 = 3, meaning that there is
// 3 bits left until we're at the 8 bit aligned byte boundary.
@(require_results)
get_align_bits :: proc(bits: u32) -> u32 {
	return (8 - (bits % 8)) % 8
}

Bit_Reader :: struct {
	buffer:       []u32,
	scratch:      u64,
	scratch_bits: u32,
	num_bits:     u32,
	bits_read:    u32,
	word_index:   u32,
}

get_writer_bits_remaining :: proc(bit_writer: Bit_Writer) -> u32 {
	return bit_writer.num_bits - bit_writer.bits_written
}

get_writer_bytes_written :: proc(bit_writer: Bit_Writer) -> u32 {
	return bit_writer.bits_written / 8
}

create_reader :: proc(buffer: []u32) -> Bit_Reader {
	bit_reader := Bit_Reader {
		buffer       = buffer,
		scratch      = 0,
		scratch_bits = 0,
		num_bits     = u32(len(buffer) * 32),
		bits_read    = 0,
		word_index   = 0,
	}
	return bit_reader
}


@(require_results)
read_bits :: proc(
	reader: ^Bit_Reader,
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

	if bits > 32 || reader.bits_read + bits > reader.num_bits {
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
	reader.bits_read += bits

	return value, true
}

// Read remaining bits until byte aligned boundary
// One thing to note is that the reader.bits_read will now be increased
// up until the next byte boundary, even if this returns false.
@(require_results)
read_align :: proc(reader: ^Bit_Reader) -> bool {
	remainder_bits := reader.bits_read % 8
	if remainder_bits != 0 {
		value, success := read_bits(reader, 8 - remainder_bits)
		if !success {
			return false
		}

		assert(reader.bits_read % 8 == 0)

		if value != 0 {
			return false
		}
	}
	return true
}

@(require_results)
read_bytes :: proc(reader: ^Bit_Reader, data: []u8, bytes: u32) -> bool {
	// NOTE: We assume that we're on byte alignment
	assert(get_align_bits(reader.bits_read) == 0)
	assert(reader.bits_read + bytes * 8 <= reader.num_bits)

	head_bytes := calculate_head_bytes(reader.bits_read)
	// If the number of bytes up to the next word boundary
	// is larger we "clamp" it to the number of bytes.
	if head_bytes > bytes {
		head_bytes = bytes
	}

	for i in 0 ..< head_bytes {
		value, success := read_bits(reader, 8)
		if !success {
			// TODO(Thomas): Flipping this does not change outcome of unit tests
			return false
		}
		// Safety: safe to cast to u8 since we only read 8 bits 
		data[i] = u8(value)
	}

	// NOTE: If head_bytes is equal to bytes, that means that there's no more
	// to read after the head_bytes. This means that we're done and can just return.
	if head_bytes == bytes {
		return true
	}

	assert(get_align_bits(reader.bits_read) == 0)

	num_words := (bytes - head_bytes) / 4
	copy_len := int(num_words) * 4
	if num_words > 0 {
		assert((reader.bits_read % 32) == 0)
		mem.copy(
			&data[head_bytes],
			&reader.buffer[reader.word_index],
			copy_len,
		)
		reader.bits_read += num_words * 32
		reader.word_index += num_words
		reader.scratch_bits = 0
	}

	assert(get_align_bits(reader.num_bits) == 0)

	tail_start := head_bytes + num_words * 4
	tail_bytes := bytes - tail_start
	assert(tail_bytes >= 0 && tail_bytes < 4)
	for i in 0 ..< tail_bytes {
		value, success := read_bits(reader, 8)
		if !success {
			return false
		}
		// Safety: Safe to cast to u8 here since we only read 8 bits into value
		data[tail_start + i] = u8(value)
	}

	assert(get_align_bits(reader.num_bits) == 0)
	assert((head_bytes + num_words * 4 + tail_bytes) == bytes)

	return true
}


get_reader_bits_remaining :: proc(bit_reader: Bit_Reader) -> u32 {
	return bit_reader.num_bits - bit_reader.bits_read
}

get_reader_bytes_read :: proc(bit_reader: Bit_Reader) -> u32 {
	return bit_reader.bits_read / 8
}

// Calulates the amount of bytes necessary to reach the next word byte boundary
// NOTE: This assumes that the bits passed in are byte aligned,
// meaning that for x = 8, 16, 24 and 32 then num_bits % x == 0
calculate_head_bytes :: proc(num_bits: u32) -> u32 {
	assert(
		num_bits % 32 == 0 ||
		num_bits % 32 == 8 ||
		num_bits % 32 == 16 ||
		num_bits % 32 == 24,
	)
	// This calulates the amount of bytes necessary to reach the next word byte boundary
	// Step 1: Calculate the remainder of bits past the current word: writer.bits_written % 32
	// Step 2: Calculate the remainder of bytes past the current word: (writer.bits_written % 32) / 8 
	// Step 3: Calculate how many bytes we're away from the next word boundary: 4 - (writer.bits_written % 32) / 8
	// Step 4: Calculate the amount of padding required to align the next word boundary: (4 - (writer.bits_written % 32) / 8) % 4
	head_bytes := (4 - (num_bits % 32) / 8) % 4
	return head_bytes
}

@(test)
test_write_zero_and_zero_bits :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0, 0)

	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.buffer[writer.word_index], 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 0)
}

@(test)
test_write_single_bit :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 1)
	testing.expect_value(t, writer.scratch_bits, 1)
	testing.expect_value(t, writer.bits_written, 1)
}

@(test)
test_write_multiple_zero_bits :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0, 3)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 3)
}

@(test)
test_write_full_word :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 32)
}

@(test)
test_write_across_word_boundary :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	res = write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 1)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 32)
}

@(test)
test_write_multiple_words :: proc(t: ^testing.T) {
	buffer := []u32{0, 0, 0}
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
	testing.expect_value(t, writer.bits_written, 3 * 32)
}

@(test)
test_write_partial_bits :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0b101, 3)
	testing.expect(t, res)
	res = write_bits(&writer, 0b11111, 5)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0b11111101)
	testing.expect_value(t, writer.scratch_bits, 8)
	testing.expect_value(t, writer.bits_written, 8)
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
	buffer := []u32{0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 0)
	testing.expect(t, res)
	testing.expect_value(t, writer.word_index, 0)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 0)
}

@(test)
test_write_mixed_bit_lengths :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer[:])

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
	buffer := []u32{0, 0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[0], 0xFFFF_FFFF)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 32)
	res = write_bits(&writer, 0b1101, 4)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[writer.word_index], 0)
	testing.expect_value(t, writer.scratch, 0b1101)
	testing.expect_value(t, writer.scratch_bits, 4)
	testing.expect_value(t, writer.bits_written, 36)
	res = flush_bits(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.buffer[1], 0b1101)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.word_index, 2)
	testing.expect_value(t, writer.bits_written, 36)
}

@(test)
test_write_flush_on_last_word :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)

	for i in 0 ..< 99 {
		res := write_bits(&writer, 0xFFFF_FFFF, 32)
		testing.expect(t, res)
		testing.expect_value(t, writer.bits_written, u32(i + 1) * 32)
	}

	testing.expect_value(t, writer.word_index, 99)
	testing.expect_value(t, writer.bits_written, 99 * 32)

	res := write_bits(&writer, 0x0000_0003, 3)
	testing.expect_value(t, writer.bits_written, (99 * 32) + 3)
	testing.expect(t, res)

	success := flush_bits(&writer)
	testing.expect(t, success)
	testing.expect_value(t, writer.buffer[99], 0x0000_0003)
	testing.expect_value(t, writer.word_index, 100)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, (99 * 32) + 3)

	res = write_bits(&writer, 0x0000_0001, 1)
	testing.expect(t, !res)
	testing.expect_value(t, writer.bits_written, (99 * 32) + 3)
}

@(test)
test_write_align :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)
	res := write_bits(&writer, 0b0000_1111, 4)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0b0000_1111)
	testing.expect_value(t, writer.scratch_bits, 4)
	testing.expect_value(t, writer.bits_written, 4)

	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0b0000_1111)
	testing.expect_value(t, writer.scratch_bits, 8)
	testing.expect_value(t, writer.bits_written, 8)
}

@(test)
test_write_align_empty_on_0th_bit :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)
	res := write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 0)
}

@(test)
test_write_align_empty_on_1th_bit :: proc(t: ^testing.T) {
	buffer := []u32{0}
	writer := create_writer(buffer)
	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 1)
	testing.expect_value(t, writer.scratch_bits, 1)
	testing.expect_value(t, writer.bits_written, 1)
	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 1)
	testing.expect_value(t, writer.scratch_bits, 8)
	testing.expect_value(t, writer.bits_written, 8)

}

@(test)
test_write_align_wrap_word :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer)

	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch_bits, 1)
	testing.expect_value(t, writer.bits_written, 1)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)
	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch_bits, 8)
	testing.expect_value(t, writer.bits_written, 8)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)
	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch_bits, 16)
	testing.expect_value(t, writer.bits_written, 16)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)
	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch_bits, 24)
	testing.expect_value(t, writer.bits_written, 24)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)

	// Write align here will wrap the word
	res = write_align(&writer)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch_bits, 0)
	testing.expect_value(t, writer.bits_written, 32)
	testing.expect_value(t, writer.word_index, 1)
}

@(test)
test_read_zero_bits :: proc(t: ^testing.T) {
	buffer := []u32{0xFFFF_FFFF}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 0)
	testing.expect(t, success)
	testing.expect_value(t, value, 0)
	testing.expect_value(t, reader.bits_read, 0)
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
	testing.expect_value(t, reader.bits_read, 1)
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
	testing.expect_value(t, reader.bits_read, 32)
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

	testing.expect_value(t, reader.bits_read, 48)
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

	testing.expect_value(t, reader.bits_read, 8)
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
	testing.expect_value(t, reader.bits_read, 32)
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

	testing.expect_value(t, reader.bits_read, 13)
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
	testing.expect_value(t, reader.bits_read, 64)
}

@(test)
test_read_large_bit_count :: proc(t: ^testing.T) {
	buffer := []u32{0xAAAA_AAAA, 0xBBBB_BBBB}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 33)
	testing.expect(t, !success)
	testing.expect_value(t, reader.bits_read, 0)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_read_empty_buffer :: proc(t: ^testing.T) {
	buffer := []u32{}
	reader := create_reader(buffer[:])

	value, success := read_bits(&reader, 1)
	testing.expect(t, !success)
	testing.expect_value(t, reader.bits_read, 0)
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

	testing.expect_value(t, reader.bits_read, 32)
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
	testing.expect_value(t, reader.bits_read, 32)
	testing.expect_value(t, reader.scratch, 0)
	testing.expect_value(t, reader.scratch_bits, 0)
}

@(test)
test_write_then_read_simple :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}

	writer := create_writer(buffer)
	success := write_bits(&writer, 0b1010, 4)
	testing.expect(t, success)
	success = write_bits(&writer, 0b11110000, 8)
	testing.expect(t, success)
	success = flush_bits(&writer)
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
	buffer := []u32{0}

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xAABB_CCDD, 32)
	testing.expect(t, success)
	success = flush_bits(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xAABB_CCDD)
}

@(test)
test_write_then_read_across_word_boundary :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xFFFF, 16)
	testing.expect(t, success)
	success = write_bits(&writer, 0xAAAA, 16)
	testing.expect(t, success)
	success = write_bits(&writer, 0xBBBB, 16)
	testing.expect(t, success)
	success = flush_bits(&writer)
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
	buffer := []u32{0}

	writer := create_writer(buffer)
	success := write_bits(&writer, 0b1, 1)
	testing.expect(t, success)
	success = write_bits(&writer, 0b1010, 4)
	testing.expect(t, success)
	success = write_bits(&writer, 0xFF, 8)
	testing.expect(t, success)
	success = write_bits(&writer, 0xABCD, 16)
	testing.expect(t, success)
	success = flush_bits(&writer)
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
	buffer := []u32{0, 0}

	writer := create_writer(buffer)
	success := write_bits(&writer, 0xFFFF_FFFF, 32)
	testing.expect(t, success)
	success = write_bits(&writer, 0xAAAA_AAAA, 32)
	testing.expect(t, success)
	success = flush_bits(&writer)
	testing.expect(t, success)

	reader := create_reader(buffer[:])
	value, read_success := read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xFFFF_FFFF)

	value, read_success = read_bits(&reader, 32)
	testing.expect(t, read_success)
	testing.expect_value(t, value, 0xAAAA_AAAA)

	// Try to read one more bit, which should fail
	value, read_success = read_bits(&reader, 1)
	testing.expect(t, !read_success)
	testing.expect_value(t, value, 0)
}

@(test)
test_read_align_one_bit :: proc(t: ^testing.T) {
	buffer := []u32{0b0000_0001}
	reader := create_reader(buffer)

	value, success := read_bits(&reader, 1)
	testing.expect(t, success)
	testing.expect_value(t, value, 1)
	testing.expect_value(t, reader.bits_read, 1)

	success = read_align(&reader)
	testing.expect(t, success)
	testing.expect_value(t, reader.bits_read, 8)
}

@(test)
test_read_align_two_bit_set_should_fail :: proc(t: ^testing.T) {
	buffer := []u32{0b0010_0001}
	reader := create_reader(buffer)

	value, success := read_bits(&reader, 1)
	testing.expect(t, success)
	testing.expect_value(t, value, 1)
	testing.expect_value(t, reader.bits_read, 1)

	success = read_align(&reader)
	testing.expect(t, !success)

	// NOTE: It's now aligned up to the next byte boundary
	testing.expect_value(t, reader.bits_read, 8)
}

@(test)
test_get_align :: proc(t: ^testing.T) {
	buffer := []u32{0, 0, 0, 0}
	writer := create_writer(buffer)

	align := get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 0)

	res := write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.bits_written, 1)

	align = get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 7)

	res = write_bits(&writer, 1, 6)
	testing.expect(t, res)
	testing.expect_value(t, writer.bits_written, 7)

	align = get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 1)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.bits_written, 8)

	align = get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 0)

	res = write_bits(&writer, 1, 32)
	testing.expect(t, res)
	testing.expect_value(t, writer.bits_written, 40)

	align = get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 0)

	res = write_bits(&writer, 1, 1)
	testing.expect(t, res)
	testing.expect_value(t, writer.bits_written, 41)

	align = get_align_bits(writer.bits_written)
	testing.expect_value(t, align, 7)
}

@(test)
test_calculate_head_bytes :: proc(t: ^testing.T) {
	// Test case 1: 32 bits -- Perfectly aligned with word boundary
	{
		bits: u32 = 32
		head_bytes := calculate_head_bytes(bits)
		testing.expect_value(t, head_bytes, 0)
	}

	// Test case 2: 0 bits -- Perfectly aligned with word boundary
	{
		bits: u32 = 0
		head_bytes := calculate_head_bytes(bits)
		testing.expect_value(t, head_bytes, 0)
	}

	// Test case 3: 8 bits -- 24 bits = 3 bytes away from word boundary
	{
		bits: u32 = 8
		head_bytes := calculate_head_bytes(bits)
		testing.expect_value(t, head_bytes, 3)
	}

	// Test case 4: 16 bits -- 16 bits = 2 bytes away from word boundary
	{
		bits: u32 = 16
		head_bytes := calculate_head_bytes(bits)
		testing.expect_value(t, head_bytes, 2)
	}

	// Test case 4: 24 bits -- 8 bits = 1 byte away from word boundary
	{
		bits: u32 = 24
		head_bytes := calculate_head_bytes(bits)
		testing.expect_value(t, head_bytes, 1)
	}
}

@(test)
test_write_bytes :: proc(t: ^testing.T) {
	// Test case 1: Write a small amount of data
	{
		buffer := []u32{0}
		writer := create_writer(buffer)
		data := []u8{0xAA, 0xBB, 0xCC}
		success := write_bytes(&writer, data)
		testing.expect(
			t,
			success,
			"Writing small amount of data should succeed",
		)
		success = flush_bits(&writer)
		testing.expect(t, success)
		testing.expect_value(t, writer.bits_written, 24)
		testing.expect_value(t, writer.buffer[0], 0x00CCBBAA)
	}

	// Test case 2: Write data that aligns perfectly with word boundaries
	{
		buffer := []u32{0, 0}
		writer := create_writer(buffer)
		data := []u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
		success := write_bytes(&writer, data)
		testing.expect(t, success, "Writing word-aligned data should succeed")
		testing.expect_value(t, writer.bits_written, 64)
		testing.expect_value(t, writer.buffer[0], 0x44332211)
		testing.expect_value(t, writer.buffer[1], 0x88776655)
	}

	// Test case 3: Write data that doesn't align with word boundaries
	{
		buffer := []u32{0, 0}
		writer := create_writer(buffer)
		data := []u8{0xAA, 0xBB, 0xCC, 0xDD, 0xEE}
		success := write_bytes(&writer, data)
		testing.expect(
			t,
			success,
			"Writing non-word-aligned data should succeed",
		)
		success = flush_bits(&writer)
		testing.expect(t, success)
		testing.expect_value(t, writer.bits_written, 40)
		testing.expect_value(t, writer.buffer[0], 0xDDCCBBAA)
		testing.expect_value(t, writer.buffer[1] & 0x00FF, 0x00EE)
	}

	// Test case 4: Write data that exceeds buffer capacity
	// TODO(Thomas): This triggers assert so it panics. Reintroduce when asserts are removed.
	//{
	//	buffer := []u32{0}
	//	writer := create_writer(buffer)
	//	data := []u8{0x11, 0x22, 0x33, 0x44, 0x55}
	//	success := write_bytes(&writer, data)
	//	testing.expect(
	//		t,
	//		!success,
	//		"Writing data exceeding buffer capacity should fail",
	//	)
	//}

	//// Test case 5: Write empty data
	{
		buffer := []u32{0}
		writer := create_writer(buffer)
		data := []u8{}
		success := write_bytes(&writer, data)
		testing.expect(t, success, "Writing empty data should succeed")
		testing.expect_value(t, writer.bits_written, 0)
	}
}

@(test)
test_read_bytes :: proc(t: ^testing.T) {
	// Test case 1: Read small amount of data that aligns with word boundary
	{
		buffer := []u32{0xDDCCBBAA}
		reader := create_reader(buffer)
		data := []u8{0, 0, 0, 0}
		success := read_bytes(&reader, data, u32(len(data)))
		testing.expect(t, success, "Reading word-aligned data should succeed")
		testing.expect_value(t, data[0], 0xAA)
		testing.expect_value(t, data[1], 0xBB)
		testing.expect_value(t, data[2], 0xCC)
		testing.expect_value(t, data[3], 0xDD)

		// Asserting reader state
		testing.expect_value(t, reader.bits_read, reader.num_bits)
	}
	// Test case 2: Read non-word aligned data
	{
		buffer := []u32{0xDDCCBBAA}
		reader := create_reader(buffer)
		data := []u8{0, 0, 0}
		success := read_bytes(&reader, data, 3)
		testing.expect(
			t,
			success,
			"Reading non-word-aligned data should succeed",
		)
		testing.expect_value(t, data[0], 0xAA)
		testing.expect_value(t, data[1], 0xBB)
		testing.expect_value(t, data[2], 0xCC)

		// Asserting reader state
		testing.expect_value(t, reader.bits_read, 3 * 8)
	}
	// Test case 3: Read overlapping words that align
	{
		buffer := []u32{0xDDCCBBAA, 0x99887766}
		reader := create_reader(buffer)
		data: [8]u8
		success := read_bytes(&reader, data[:], 8)
		testing.expect(
			t,
			success,
			"Reading non-word-aligned data should succeed",
		)
		// First word
		testing.expect_value(t, data[0], 0xAA)
		testing.expect_value(t, data[1], 0xBB)
		testing.expect_value(t, data[2], 0xCC)
		testing.expect_value(t, data[3], 0xDD)

		// Second word
		testing.expect_value(t, data[4], 0x66)
		testing.expect_value(t, data[5], 0x77)
		testing.expect_value(t, data[6], 0x88)
		testing.expect_value(t, data[7], 0x99)

		// Asserting reader state
		testing.expect_value(t, reader.bits_read, reader.num_bits)
	}

	// Test case 4: Read overlapping words that doest not align
	{
		buffer := []u32{0xDDCCBBAA, 0x99887766}
		reader := create_reader(buffer)
		data: [8]u8
		success := read_bytes(&reader, data[:], 7)
		testing.expect(
			t,
			success,
			"Reading non-word-aligned data should succeed",
		)
		// First word
		testing.expect_value(t, data[0], 0xAA)
		testing.expect_value(t, data[1], 0xBB)
		testing.expect_value(t, data[2], 0xCC)
		testing.expect_value(t, data[3], 0xDD)

		// Second word
		testing.expect_value(t, data[4], 0x66)
		testing.expect_value(t, data[5], 0x77)
		testing.expect_value(t, data[6], 0x88)

		// Asserting reader state
		testing.expect_value(t, reader.bits_read, 7 * 8)
	}

	// Test case 5: Read zero bytes
	{
		buffer := []u32{0x0000_0000}
		reader := create_reader(buffer)

		data: [4]u8
		success := read_bytes(&reader, data[:], 0)
		testing.expect(t, success, "Reading zero bytes should succeed")
		testing.expect_value(t, data[0], 0)
		testing.expect_value(t, data[1], 0)
		testing.expect_value(t, data[2], 0)
		testing.expect_value(t, data[3], 0)

		testing.expect_value(t, reader.bits_read, 0)
		testing.expect_value(t, reader.scratch, 0)
		testing.expect_value(t, reader.scratch_bits, 0)
	}

	// Test case 6: Head bytes = bytes
	{
		buffer := []u32{0x0000_0000, 0x0000_0000}
		reader := create_reader(buffer)

		data: [4]u8
		success := read_bytes(&reader, data[:], 1)
		testing.expect(t, success, "Reading initial two bytes should succeed")
		testing.expect_value(t, reader.bits_read, 8)

		// Now we have set up a situation where head_bytes will be 2 inside of the reader on next read.
		testing.expect_value(t, calculate_head_bytes(reader.bits_read), 3)

		success_two := read_bytes(&reader, data[:], 2)
		testing.expect(t, success_two, "Reading next two bytes should succeed")
		testing.expect_value(t, reader.bits_read, 24)
	}
}
