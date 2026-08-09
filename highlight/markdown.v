module highlight

import markdown

pub fn convert_markdown_to_html(code string) string {
	rendered := markdown.to_html(code).trim_right('\n')

	// Raw HTML is disabled in the renderer, but Markdown links and images still
	// create href/src attributes. Keep relative links and an explicit allowlist
	// of network schemes; everything else (notably javascript: and data:) loses
	// the dangerous attribute.
	return sanitize_rendered_markdown_urls(rendered)
}

fn sanitize_rendered_markdown_urls(html string) string {
	mut out := html
	for attribute in ['href', 'src'] {
		needle := '${attribute}="'
		mut search_from := 0
		for {
			start := out.index_after_(needle, search_from)
			if start < 0 {
				break
			}
			value_start := start + needle.len
			rel_end := out[value_start..].index('"') or { break }
			value_end := value_start + rel_end
			value := out[value_start..value_end]
			if !is_safe_markdown_url(value) {
				out = out[..start] + out[value_end + 1..]
				search_from = start
				continue
			}
			search_from = value_end + 1
		}
	}
	return out
}

fn is_safe_markdown_url(value string) bool {
	trimmed := value.trim_space()
	if trimmed == '' || trimmed.starts_with('#') || trimmed.starts_with('/')
		|| trimmed.starts_with('./') || trimmed.starts_with('../') {
		return true
	}
	mut normalized_bytes := []u8{cap: trimmed.len}
	for ch in trimmed.to_lower().bytes() {
		if ch > 0x20 && ch != 0x7f {
			normalized_bytes << ch
		}
	}
	normalized := normalized_bytes.bytestr()
	colon := normalized.index(':') or { return true }
	boundary := normalized.index_any('/?#')
	if boundary >= 0 && boundary < colon {
		return true
	}
	scheme := normalized[..colon]
	return scheme in ['http', 'https', 'mailto']
}
