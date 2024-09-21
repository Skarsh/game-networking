package protocol

import "core:hash"
import "core:math"
import "core:testing"

// Checks if a sequence number is greater than the other.
// Involves a trick where it checks that the sequence numbers
// are within half the range of a u16 (2^16 / 2 = 32768) of each other.
// If they are not we can assume that the sequence number have wrapped around
// to the beginning. 
sequence_greater_than :: proc(s1: u16, s2: u16) -> bool {
	// 32768 = 2^16 / 2
	return(
		((s1 > s2) && (s1 - s2 <= 32768)) ||
		((s1 < s2) && (s2 - s1 >= 32768)) \
	)
}

sequence_less_than :: proc(s1: u16, s2: u16) -> bool {
	return sequence_greater_than(s2, s1)
}

// TODO(Thomas): Add tests for this one
sequence_difference :: proc(s1: u16, s2: u16) -> int {
	signed_s1 := int(s1)
	signed_s2 := int(s2)
	if (math.abs(signed_s1 - signed_s2) >= 32768) {
		if (signed_s1 > signed_s2) {
			signed_s2 += 65536
		} else {
			signed_s1 += 65536
		}
	}
	return signed_s1 - signed_s2
}


calculate_crc32 :: proc(data: []byte) -> u32 {
	return hash.crc32(data)
}

@(test)
test_sequence_greater_than :: proc(t: ^testing.T) {

	// Test case 1: 
	// Equal case
	testing.expect(t, sequence_greater_than(0, 0) == false)

	// Test case 2: 
	// Basic greather than case
	testing.expect(t, sequence_greater_than(1, 0) == true)

	// Test case 3: 
	// At the maximum of the wrap-around range, 
	// so we assume that s2 has not wrapped around hence s1
	// is "greater" than s2
	testing.expect(t, sequence_greater_than(32768, 0) == true)

	// Test case 4: 
	// One beyond the wrap-around range, so we assume s2 has wrapped around
	// and we assume that s2 is "greater" than s1 here.
	testing.expect(t, sequence_greater_than(32769, 0) == false)

	// Test case 5: 
	// At the max value of u16, beyond wrap around range.
	// We assume that s2 has wrapped around here, hence s2 is "greater"
	testing.expect(t, sequence_greater_than(65535, 0) == false)

	// Test case 6: 
	// S1 has wrapped around but s2 has not, 
	// meaning s1 is still "greater" than s2
	testing.expect(t, sequence_greater_than(0, 65535) == true)

	// Test case 7: 
	// S1 has wrapped around but s2 has not, 
	// meaning s1 is still "greater" than s2
	testing.expect(t, sequence_greater_than(1, 65535) == true)

	// Test case 8:
	// s1 < s2 and s2 - s1 > 32768, so we assume s1 has wrapped around, hence s1 is deemed "greater"
	testing.expect(t, sequence_greater_than(32767, 65535) == true)

	// Test case 9:
	// s2 > s1 and they are within range of each other, hence we assume s2 is "greater"
	testing.expect(t, sequence_greater_than(32768, 65535) == false)

	// Simple cases
	testing.expect(t, sequence_greater_than(100, 200) == false)
	testing.expect(t, sequence_greater_than(200, 100) == true)
}

@(test)
test_sequence_less_than :: proc(t: ^testing.T) {
	// Same cases as for the greater than, just flipped.
	testing.expect(t, sequence_less_than(0, 0) == false)
	testing.expect(t, sequence_less_than(0, 1) == true)
	testing.expect(t, sequence_less_than(0, 32768) == true)
	testing.expect(t, sequence_less_than(0, 32769) == false)
	testing.expect(t, sequence_less_than(0, 65535) == false)
	testing.expect(t, sequence_less_than(65535, 0) == true)
	testing.expect(t, sequence_less_than(65535, 1) == true)
	testing.expect(t, sequence_less_than(65535, 32767) == true)
	testing.expect(t, sequence_less_than(65535, 32768) == false)
	testing.expect(t, sequence_less_than(200, 100) == false)
	testing.expect(t, sequence_less_than(100, 200) == true)
}
