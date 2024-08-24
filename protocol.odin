package main

import "core:testing"

sequence_greater_than :: proc(s1: u16, s2: u16) -> bool {
	// 32768 = 2^16 / 2
	return(
		((s1 > s2) && (s1 - s2 <= 32768)) ||
		((s1 < s2) && (s2 - s1 > 32768)) \
	)
}

sequence_less_than :: proc(s1: u16, s2: u16) -> bool {
	return sequence_greater_than(s2, s1)
}

@(test)
test_sequence_greater_than :: proc(t: ^testing.T) {
	testing.expect(t, sequence_greater_than(1, 0) == true)
	testing.expect(t, sequence_greater_than(32768, 0) == true)

	testing.expect(t, sequence_greater_than(32769, 0) == false)

}
