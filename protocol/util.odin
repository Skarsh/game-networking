package protocol

import "core:log"

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
