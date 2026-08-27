module main

import os

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

fn test_check_last_page_handles_full_and_partial_final_pages() {
	assert check_last_page(0, 0, 30)
	assert check_last_page(30, 0, 30)
	assert !check_last_page(31, 0, 30)
	assert check_last_page(60, 30, 30)
}

fn test_create_directory_if_not_exists_creates_nested_paths() {
	root := os.join_path(os.temp_dir(), 'gitly_nested_directory_${os.getpid()}')
	nested := os.join_path(root, 'one', 'two')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}

	create_directory_if_not_exists(nested)
	assert os.is_dir(nested)
	// Calling it again must be idempotent.
	create_directory_if_not_exists(nested)
}
