module main

fn test_strip_intertag_whitespace_compacts_template_indentation() {
	html := '<div>\n\t<span>\n\t\tFiles changed\n\t</span>\n</div>'

	assert strip_intertag_whitespace(html) == '<div><span>Files changed</span></div>'
}

fn test_strip_intertag_whitespace_trims_quoted_attribute_values() {
	html := '<input placeholder="Search...\n" aria-label=" Files changed\n">'

	assert strip_intertag_whitespace(html) == '<input placeholder="Search..." aria-label="Files changed">'
}

fn test_strip_intertag_whitespace_preserves_diff_code_text() {
	html := '<s>\t<b>return</b> <b>false</b></s>'

	assert strip_intertag_whitespace(html) == html
}
