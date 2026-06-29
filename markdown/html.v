module markdown

import strings

fn C.md_html(const_input &char, input_size u32, process_output ProcessFn, userdata voidptr, parser_flags u32, renderer_flags u32) int

const need_html_esc_flag = 0x1
const need_url_esc_flag = 0x2
const md_html_flag_debug = 0x0001
const md_html_flag_verbatim_entities = 0x0002
const md_html_flag_skip_utf8_bom = 0x0004
const md_flag_permissive_url_autolinks = 0x0004
const md_flag_permissive_email_autolinks = 0x0008
const md_flag_tables = 0x0100
const md_flag_strikethrough = 0x0200
const md_flag_permissive_www_autolinks = 0x0400
const md_flag_tasklists = 0x0800
const md_flag_permissive_autolinks = md_flag_permissive_url_autolinks | md_flag_permissive_email_autolinks | md_flag_permissive_www_autolinks
const md_dialect_github = md_flag_permissive_autolinks | md_flag_tables | md_flag_strikethrough | md_flag_tasklists

type ProcessFn = fn (const_t &char, s u32, x voidptr)

fn write_data_cb(const_txt &char, size u32, userdata voidptr) {
	s := unsafe { tos(&u8(const_txt), int(size)) }
	mut sb := unsafe { &strings.Builder(userdata) }
	sb.write_string(s)
}

pub fn to_html(input string) string {
	mut wr := strings.new_builder(200)
	C.md_html(input.str, input.len, write_data_cb, &wr, md_dialect_github, 0)
	return wr.str().trim_space()
}
