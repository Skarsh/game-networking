package protocol

import "core:log"
import "core:math/rand"

Test_Redirect_Logger :: struct {
	// Add fields you need to track
	messages: [dynamic]string,
}

destroy_test_redirect_logger :: proc(custom_logger: ^Test_Redirect_Logger) {
	delete(custom_logger.messages)
}

test_redirect_log_handler :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: bit_set[log.Option],
	location := #caller_location,
) {
	logger := cast(^Test_Redirect_Logger)data
	append(&logger.messages, text)
}

random_vector2 :: proc(lo: f32, hi: f32) -> Vector2 {
	return Vector2{rand.float32_range(lo, hi), rand.float32_range(lo, hi)}
}

random_vector3 :: proc(lo: f32, hi: f32) -> Vector3 {
	return Vector3 {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}
