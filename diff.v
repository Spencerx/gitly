// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import highlight
import strings

fn render_diff_table(fd FileDiff) veb.RawHtml {
	mut out := strings.new_builder(1024)
	out.write_string('<div class=pr-diff__table>')
	for hunk in fd.hunks {
		out.write_string(diff_hunk_header_html(hunk.header))
		for dline in hunk.lines {
			out.write_string(diff_line_row_html(fd.path, dline))
		}
	}
	out.write_string('</div>')
	return veb.RawHtml(out.str())
}

fn diff_hunk_header_html(header string) string {
	return '<p class=h><code>${html_escape_text(header)}</code></p>'
}

fn diff_line_row_html(file_path string, dline DiffLine) string {
	return diff_line_row_html_with_attrs(file_path, dline, '')
}

fn diff_line_row_html_with_attrs(file_path string, dline DiffLine, attrs string) string {
	return '<p class=${dline.compact_class()}${attrs}><u>${dline.old_line_str()}</u><u>${dline.new_line_str()}</u><i>${dline.compact_sign()}</i><s>${highlight.highlight_line(dline.content,
		file_path)}</s></p>'
}

struct FileDiff {
mut:
	path       string
	old_path   string
	is_new     bool
	is_deleted bool
	is_renamed bool
	is_binary  bool
	additions  int
	deletions  int
	hunks      []DiffHunk
}

struct DiffHunk {
mut:
	header    string
	old_start int
	old_count int
	new_start int
	new_count int
	lines     []DiffLine
}

struct DiffLine {
mut:
	kind     string // 'context', 'add', 'del'
	old_line int    // 0 if not applicable
	new_line int    // 0 if not applicable
	content  string
}

// parse_unified_diff parses a `git diff` unified diff into FileDiff structs.
fn parse_unified_diff(raw string) []FileDiff {
	mut files := []FileDiff{}
	mut cur := FileDiff{}
	mut cur_hunk := DiffHunk{}
	mut in_file := false
	mut in_hunk := false
	mut old_l := 0
	mut new_l := 0

	for line in raw.split_into_lines() {
		if line.starts_with('diff --git') {
			if in_file {
				if in_hunk {
					cur.hunks << cur_hunk
				}
				files << cur
			}
			cur = FileDiff{}
			cur_hunk = DiffHunk{}
			in_file = true
			in_hunk = false
			a_path, b_path := parse_diff_git_paths(line)
			if a_path != '' || b_path != '' {
				cur.old_path = a_path
				cur.path = b_path
			}
		} else if line.starts_with('new file') {
			cur.is_new = true
		} else if line.starts_with('deleted file') {
			cur.is_deleted = true
		} else if line.starts_with('rename from ') {
			cur.is_renamed = true
			cur.old_path = parse_diff_path_value(line['rename from '.len..])
		} else if line.starts_with('rename to ') {
			cur.is_renamed = true
			cur.path = parse_diff_path_value(line['rename to '.len..])
		} else if line.starts_with('Binary files') {
			cur.is_binary = true
			old_path, new_path := parse_binary_diff_paths(line)
			if old_path != '' && old_path != '/dev/null' {
				cur.old_path = strip_diff_prefix(old_path, 'a/')
			}
			if new_path != '' && new_path != '/dev/null' {
				cur.path = strip_diff_prefix(new_path, 'b/')
			}
		} else if line.starts_with('--- ') {
			old_path := parse_diff_marker_path(line[4..])
			if old_path != '/dev/null' {
				cur.old_path = strip_diff_prefix(old_path, 'a/')
			}
		} else if line.starts_with('+++ ') {
			new_path := parse_diff_marker_path(line[4..])
			if new_path != '/dev/null' {
				cur.path = strip_diff_prefix(new_path, 'b/')
			}
		} else if line.starts_with('@@') {
			if in_hunk {
				cur.hunks << cur_hunk
			}
			cur_hunk = DiffHunk{
				header: line
			}
			in_hunk = true
			parse_hunk_header(line, mut cur_hunk)
			old_l = cur_hunk.old_start
			new_l = cur_hunk.new_start
		} else if in_hunk && line.len > 0 {
			first := line[0]
			content := line[1..]
			if first == ` ` {
				cur_hunk.lines << DiffLine{
					kind:     'context'
					old_line: old_l
					new_line: new_l
					content:  content
				}
				old_l++
				new_l++
			} else if first == `+` {
				cur_hunk.lines << DiffLine{
					kind:     'add'
					new_line: new_l
					content:  content
				}
				new_l++
				cur.additions++
			} else if first == `-` {
				cur_hunk.lines << DiffLine{
					kind:     'del'
					old_line: old_l
					content:  content
				}
				old_l++
				cur.deletions++
			} else if first == `\\` {
				// "\ No newline at end of file" — ignore
			}
		}
	}
	if in_file {
		if in_hunk {
			cur.hunks << cur_hunk
		}
		files << cur
	}
	return files
}

// Git's `diff --git` header is not shell-tokenized: ordinary paths containing
// spaces are emitted without quotes. The ` b/` boundary is therefore the only
// delimiter available in that header. Later ---/+++, rename, and binary
// headers carry authoritative paths and replace these provisional values.
fn parse_diff_git_paths(line string) (string, string) {
	prefix := 'diff --git '
	if !line.starts_with(prefix) {
		return '', ''
	}
	rest := line[prefix.len..]
	if rest.starts_with('"') {
		old_value, next := parse_git_quoted_path_at(rest, 0)
		new_value, _ := parse_git_quoted_path_at(rest, next)
		return strip_diff_prefix(old_value, 'a/'), strip_diff_prefix(new_value, 'b/')
	}
	separator := rest.index(' b/') or { return '', '' }
	return strip_diff_prefix(rest[..separator], 'a/'), strip_diff_prefix(rest[separator + 1..],
		'b/')
}

fn parse_diff_marker_path(value string) string {
	if value.starts_with('"') {
		path, _ := parse_git_quoted_path_at(value, 0)
		return path
	}
	// Traditional unified diffs may append a timestamp after a tab. Git also
	// appends a tab for an unquoted path containing spaces.
	return value.all_before('\t')
}

fn parse_diff_path_value(value string) string {
	if value.starts_with('"') {
		path, _ := parse_git_quoted_path_at(value, 0)
		return path
	}
	return value
}

fn parse_binary_diff_paths(line string) (string, string) {
	prefix := 'Binary files '
	suffix := ' differ'
	if !line.starts_with(prefix) || !line.ends_with(suffix) {
		return '', ''
	}
	rest := line[prefix.len..line.len - suffix.len]
	if rest.starts_with('"') {
		old_value, next := parse_git_quoted_path_at(rest, 0)
		and_at := rest.index_after_(' and ', next)
		if and_at < 0 {
			return '', ''
		}
		new_value, _ := parse_git_quoted_path_at(rest, and_at + ' and '.len)
		return old_value, new_value
	}
	separator := rest.index(' and b/') or {
		separator_null := rest.index(' and /dev/null') or { return '', '' }
		return rest[..separator_null], rest[separator_null + ' and '.len..]
	}
	return rest[..separator], rest[separator + ' and '.len..]
}

// Git double-quotes unusual paths using C-style escapes. Decode the escapes so
// paths used by the file tree, syntax highlighter, and inline-comment keys all
// refer to the real repository path.
fn parse_git_quoted_path_at(value string, start int) (string, int) {
	mut i := start
	for i < value.len && value[i] == ` ` {
		i++
	}
	if i >= value.len || value[i] != `"` {
		end := value.index_after_(' ', i)
		if end < 0 {
			return value[i..], value.len
		}
		return value[i..end], end
	}
	i++
	mut decoded := []u8{cap: value.len - i}
	for i < value.len {
		ch := value[i]
		if ch == `"` {
			return decoded.bytestr(), i + 1
		}
		if ch != `\\` || i + 1 >= value.len {
			decoded << ch
			i++
			continue
		}
		i++
		escaped := value[i]
		match escaped {
			`a` {
				decoded << u8(7)
			}
			`b` {
				decoded << u8(8)
			}
			`t` {
				decoded << `\t`
			}
			`n` {
				decoded << `\n`
			}
			`v` {
				decoded << u8(11)
			}
			`f` {
				decoded << u8(12)
			}
			`r` {
				decoded << `\r`
			}
			`"`, `\\` {
				decoded << escaped
			}
			else {
				if escaped >= `0` && escaped <= `7` {
					mut octal := int(escaped - `0`)
					mut digits := 1
					for digits < 3 && i + 1 < value.len && value[i + 1] >= `0`
						&& value[i + 1] <= `7` {
						i++
						digits++
						octal = octal * 8 + int(value[i] - `0`)
					}
					decoded << u8(octal)
				} else {
					decoded << escaped
				}
			}
		}
		i++
	}
	return decoded.bytestr(), i
}

fn (d &DiffLine) compact_sign() string {
	return match d.kind {
		'add' { '+' }
		'del' { '-' }
		else { '' }
	}
}

fn (d &DiffLine) compact_class() string {
	return match d.kind {
		'add' { 'a' }
		'del' { 'd' }
		else { 'c' }
	}
}

fn (d &DiffLine) compact_side() string {
	return match d.kind {
		'add' { 'n' }
		'del' { 'o' }
		else { '' }
	}
}

fn (d &DiffLine) side() string {
	return if d.kind == 'add' { 'new' } else { 'old' }
}

fn (d &DiffLine) effective_line() int {
	return if d.kind == 'add' { d.new_line } else { d.old_line }
}

fn (d &DiffLine) comment_field_name(file_path string) string {
	return 'rc::${file_path}::${d.side()}::${d.effective_line()}'
}

fn (d &DiffLine) old_line_str() string {
	return if d.old_line > 0 { d.old_line.str() } else { '' }
}

fn (d &DiffLine) new_line_str() string {
	return if d.new_line > 0 { d.new_line.str() } else { '' }
}

fn strip_diff_prefix(s string, prefix string) string {
	if s.starts_with(prefix) {
		return s[prefix.len..]
	}
	return s
}

// parse_hunk_header parses lines like "@@ -1,3 +1,4 @@ optional context"
fn parse_hunk_header(line string, mut hunk DiffHunk) {
	parts := line.split(' ')
	for p in parts {
		if p.len < 2 {
			continue
		}
		if p[0] == `-` {
			start, count := parse_range(p[1..])
			hunk.old_start = start
			hunk.old_count = count
		} else if p[0] == `+` {
			start, count := parse_range(p[1..])
			hunk.new_start = start
			hunk.new_count = count
		}
	}
}

fn parse_range(s string) (int, int) {
	idx := s.index(',') or { return s.int(), 1 }
	return s[..idx].int(), s[idx + 1..].int()
}
