package main

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
	sequence:           u32, // packet sequence number
	num_fragments:      u32, // number of fragments for this packet
	received_fragments: u32, // number of received fragments so far
	fragment_size:      [MaxFragmentsPerPacket]i32, // size of fragment n in bytes
	fragment_data:      [MaxFragmentsPerPacket][]u8, // point to data for fragment n
}

PacketBuffer :: struct {
	current_sequence:       u16,
	num_buffered_fragments: int,
	valid:                  [PacketBufferSize]bool,
	entries:                [PacketBufferSize]PacketBufferEntry,
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
