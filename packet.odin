package main

import "core:log"
import "core:mem"
import "core:testing"

PacketBufferSize :: 256
MaxFragmentSize :: 1024
MaxFragmentsPerPacket :: 256

MaxPacketSize :: MaxFragmentSize * MaxFragmentsPerPacket

ProtocolId :: 0x55667788
PacketFragmentHeaderBytes :: 16

PacketType :: enum {
	PacketFragment = 0,
	TestPacketA,
	TestPacketB,
}

FragmentPacket :: struct {
	// input / output
	fragment_size: u32,

	// serialized data
	crc32:         u32,
	sequence:      u16,
	packet_type:   PacketType,
	fragment_id:   u8,
	num_fragments: u8,
	fragment_data: [MaxFragmentSize]u8,
}

@(require_results)
serialize_fragment_packet :: proc(
	bit_writer: ^BitWriter,
	fragment_packet: ^FragmentPacket,
) -> bool {
	if !write_bits(bit_writer, fragment_packet.crc32, 32) {
		return false
	}

	if !write_bits(bit_writer, u32(fragment_packet.sequence), 16) {
		return false
	}

	if !serialize_integer(
		bit_writer,
		i32(fragment_packet.packet_type),
		0,
		len(PacketType) - 1,
	) {
		return false
	}

	// What??
	if fragment_packet.packet_type != .PacketFragment {
		return true
	}

	if !write_bits(bit_writer, u32(fragment_packet.fragment_id), 8) {
		return false
	}

	if !write_bits(bit_writer, u32(fragment_packet.num_fragments), 8) {
		return false
	}

	if !serialize_align(bit_writer) {
		return false
	}

	assert(fragment_packet.fragment_size > 0)
	assert(fragment_packet.fragment_size <= MaxFragmentSize)

	// TODO(Thomas): Do we need to change serialize_bytes to take in the size to serialize? Or is it enough to just sub-slice correctly?
	if !serialize_bytes(
		bit_writer,
		fragment_packet.fragment_data[:fragment_packet.fragment_size],
	) {
		return false
	}

	return true
}

@(require_results)
deserialize_fragment_packet :: proc(
	bit_reader: ^BitReader,
) -> (
	FragmentPacket,
	bool,
) {
	crc32, success_crc32 := read_bits(bit_reader, 32)
	if !success_crc32 {return {}, false}

	sequence, success_sequence := read_bits(bit_reader, 16)
	if !success_sequence {return {}, false}

	packet_type_value, packet_type_success := deserialize_integer(
		bit_reader,
		0,
		len(PacketType) - 1,
	)
	if !packet_type_success {return {}, false}

	packet_type := PacketType(packet_type_value)

	if packet_type != PacketType.PacketFragment {return {}, true}

	fragment_id, success_fragment_id := read_bits(bit_reader, 8)
	if !success_fragment_id {return {}, false}

	num_fragments, success_num_fragments := read_bits(bit_reader, 8)
	if !success_num_fragments {return {}, false}

	success_align := deserialize_align(bit_reader)
	if !success_align {return {}, false}

	assert((get_reader_bits_remaining(bit_reader^) % 8) == 0)
	fragment_size := get_reader_bits_remaining(bit_reader^) / 8

	assert(fragment_size > 0)
	assert(fragment_size <= MaxFragmentSize)

	fragment_packet := FragmentPacket{}

	success_fragment_data := deserialize_bytes(
		bit_reader,
		fragment_packet.fragment_data[:],
		u32(fragment_size),
	)
	if !success_fragment_data {return {}, false}

	fragment_packet.crc32 = crc32
	fragment_packet.sequence = u16(sequence)
	fragment_packet.packet_type = packet_type
	fragment_packet.fragment_id = u8(fragment_id)
	fragment_packet.num_fragments = u8(num_fragments)
	fragment_packet.fragment_size = fragment_size

	return fragment_packet, true

}

PacketBufferEntry :: struct {
	sequence:           u16, // packet sequence number
	num_fragments:      u32, // number of fragments for this packet
	received_fragments: u32, // number of received fragments so far
	fragment_size:      [MaxFragmentsPerPacket]u32, // size of fragment n in bytes
	fragment_data:      [MaxFragmentsPerPacket][]u8, // point to data for fragment n
}

// TODO(Thomas): Valid can be turned into a bitset probably
PacketBuffer :: struct {
	current_sequence:       u16,
	num_buffered_fragments: int,
	valid:                  [PacketBufferSize]bool,
	entries:                [PacketBufferSize]PacketBufferEntry,
}

// Advance the current sequence for the packet buffer forward.
// Removes old packet entries and frees their fragments
advance_sequence :: proc(packet_buffer: ^PacketBuffer, sequence: u16) {
	if !sequence_greater_than(packet_buffer.current_sequence, sequence) {
		return
	}

	oldest_sequence: u16 = sequence - PacketBufferSize + 1
	for i in 0 ..< PacketBufferSize {
		if packet_buffer.valid[i] {
			if sequence_less_than(
				packet_buffer.entries[i].sequence,
				oldest_sequence,
			) {
				log.infof(
					"remove old packet entry %v",
					packet_buffer.entries[i].sequence,
				)
				for j in 0 ..< packet_buffer.entries[i].num_fragments {

					// TODO(Thomas): Think about this part more!!! 
					// I would prefer to free in blocks / chunks instead of one by one like this.
					// But we need to explore more of the code / solution first.
					delete(packet_buffer.entries[i].fragment_data[j])
					assert(packet_buffer.num_buffered_fragments > 0)
					packet_buffer.num_buffered_fragments -= 1
				}
			}
			// TODO(Thomas): Think about this more too! Not sure if we want to do it like this
			mem.set(&packet_buffer.entries[i], 0, size_of(PacketBufferEntry))
			packet_buffer.valid[i] = false
		}
	}
	packet_buffer.current_sequence = sequence
}

// Process packet fragment on receiver side.
// Stores each fragment ready to receive the whole packet once all fragments for the packet are received.
// If any fragment is dropped, fragments are not resent, the whole packet is dropped.

// NOTE: This function is fairly complicated because it must handle all possible cases
//       of malicously constructed packets attempting to overflow and corrupt the packet buffer!
process_fragment :: proc(
	packet_buffer: ^PacketBuffer,
	fragment_data: []u8,
	fragment_size: u32,
	packet_sequence: u16,
	fragment_id: u32,
	num_fragments_in_packet: u32,
) -> bool {
	assert(len(fragment_data) > 0)

	// fragment size is <= zero? discard the fragment

	if fragment_size <= 0 {
		return false
	}

	// fragment size exceeds max fragment size? discard the fragment

	if fragment_size > MaxFragmentSize {
		return false
	}

	// num fragments outside of range? discard the fragment

	if num_fragments_in_packet <= 0 ||
	   num_fragments_in_packet > MaxFragmentsPerPacket {
		return false
	}

	// fragment index out for range? discard the fragment

	if fragment_id < 0 || fragment_id >= num_fragments_in_packet {
		return false
	}

	// if this is not the last fragment in the packet and fragment size is not equal to MaxFragmentSize, discard the fragment
	if fragment_id != num_fragments_in_packet - 1 &&
	   fragment_size != MaxFragmentSize {
		return false
	}

	// packet sequence number wildly out of range from the current sequence? discard the fragment

	if sequence_difference(packet_sequence, packet_buffer.current_sequence) >
	   1024 {
		return false
	}

	// if the entry exists, but has a different sequence number, discard the fragment
	index := packet_sequence % PacketBufferSize

	if packet_buffer.valid[index] &&
	   packet_buffer.entries[index].sequence != packet_sequence {
		return false
	}

	// if the entry does not exist, add an entry for this sequence # and set total fragments 

	if !packet_buffer.valid[index] {
		advance_sequence(packet_buffer, packet_sequence)
		packet_buffer.entries[index].sequence = packet_sequence
		packet_buffer.entries[index].num_fragments = num_fragments_in_packet

		// IMPORTANT: Should have already been cleared to zeros in "advance_sequence" procedure
		assert(packet_buffer.entries[index].received_fragments == 0)
		packet_buffer.valid[index] = true
	}

	// at this point the entry must exist and have the same sequence number as the fragment

	assert(packet_buffer.valid[index])
	assert(packet_buffer.entries[index].sequence == packet_sequence)

	// if the total number fragments is different for this packet vs. the entry, discard the fragment

	if num_fragments_in_packet != packet_buffer.entries[index].num_fragments {
		return false
	}

	// if this fragment has already been received, ignore it because it must have come from a duplicate packet 

	assert(fragment_id < num_fragments_in_packet)
	assert(fragment_id < MaxFragmentsPerPacket)
	assert(num_fragments_in_packet <= MaxFragmentsPerPacket)

	// TODO(Thomas): What is the purpose of this??
	if packet_buffer.entries[index].fragment_size[fragment_id] == 1 {
		return false
	}

	// add the fragment to the packet buffer

	log.infof(
		"Added fragment %v of packet %v to buffer",
		fragment_id,
		packet_sequence,
	)

	assert(fragment_size > 0)
	assert(fragment_size <= MaxFragmentSize)

	packet_buffer.entries[index].fragment_size[fragment_id] = fragment_size
	packet_buffer.entries[index].fragment_data = make([]u8, fragment_size)
	mem.copy(
		&packet_buffer.entries[index].fragment_data[fragment_id],
		raw_data(fragment_data),
		int(fragment_size),
	)
	packet_buffer.entries[index].received_fragments += 1

	assert(
		packet_buffer.entries[index].received_fragments <=
		packet_buffer.entries[index].num_fragments,
	)
	packet_buffer.num_buffered_fragments += 1

	return true
}

process_packet :: proc(packet_buffer: ^PacketBuffer, data: []u8) -> bool {
	u32_data := transmute([]u32)mem.slice_ptr(&data[0], len(data))
	reader := create_reader(u32_data)

	fragment_packet, success := deserialize_fragment_packet(&reader)
	if !success {
		log.errorf("Fragment packet failed to serialize")
		return false
	}

	protocol_id := ProtocolId
	crc32 := calculate_crc32(
		transmute([]byte)mem.slice_ptr(&protocol_id, size_of(protocol_id)),
	)
	// TODO(Thomas): More crc32 stuff here

	if crc32 != fragment_packet.crc32 {
		log.errorf(
			"Corrupt packet: expected crc32 %v, got %v",
			crc32,
			fragment_packet.crc32,
		)
	}

	if fragment_packet.packet_type == PacketType.PacketFragment {
		return process_fragment(
			packet_buffer,
			data[PacketFragmentHeaderBytes:],
			fragment_packet.fragment_size,
			fragment_packet.sequence,
			u32(fragment_packet.fragment_id),
			u32(fragment_packet.num_fragments),
		)
	} else {
		return process_fragment(
			packet_buffer,
			data,
			u32(len(data)),
			fragment_packet.sequence,
			0,
			1,
		)
	}

	return true
}

@(test)
test_serialize_deserialize_fragment_packet :: proc(t: ^testing.T) {
	buffer := make([]u32, MaxFragmentSize / 32)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	fragment_packet := FragmentPacket {
		fragment_size = 72,
		crc32         = 42,
		sequence      = 16,
		packet_type   = .PacketFragment,
		fragment_id   = 14,
		num_fragments = 3,
	}

	res := serialize_fragment_packet(&writer, &fragment_packet)
	testing.expect(t, res)

	packet, success := deserialize_fragment_packet(&reader)
	testing.expect(t, success)

	testing.expect_value(t, fragment_packet, packet)
}
