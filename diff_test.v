module main

fn test_parse_unified_diff_preserves_paths_with_spaces() {
	raw := 'diff --git a/docs/old name.txt b/docs/new name.txt\n' + 'similarity index 80%\n' +
		'rename from docs/old name.txt\n' + 'rename to docs/new name.txt\n' +
		'--- a/docs/old name.txt\t\n' + '+++ b/docs/new name.txt\t\n' + '@@ -1 +1 @@\n' + '-old\n' +
		'+new\n'
	files := parse_unified_diff(raw)
	assert files.len == 1
	assert files[0].old_path == 'docs/old name.txt'
	assert files[0].path == 'docs/new name.txt'
	assert files[0].is_renamed
	assert files[0].deletions == 1
	assert files[0].additions == 1
}

fn test_parse_unified_diff_decodes_git_quoted_paths() {
	raw := r'diff --git "a/caf\303\251.txt" "b/caf\303\251.txt"' + '\n' +
		r'--- "a/caf\303\251.txt"' + '\n' + r'+++ "b/caf\303\251.txt"' + '\n' +
		'@@ -1 +1 @@\n-old\n+new\n'
	files := parse_unified_diff(raw)
	assert files.len == 1
	assert files[0].old_path == 'café.txt'
	assert files[0].path == 'café.txt'
}

fn test_parse_unified_diff_preserves_binary_path_with_spaces() {
	raw := 'diff --git a/assets/image old.png b/assets/image new.png\n' +
		'Binary files a/assets/image old.png and b/assets/image new.png differ\n'
	files := parse_unified_diff(raw)
	assert files.len == 1
	assert files[0].old_path == 'assets/image old.png'
	assert files[0].path == 'assets/image new.png'
	assert files[0].is_binary
}
