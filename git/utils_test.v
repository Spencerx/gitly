module git

fn test_get_branch_name_from_reference() {
	assert get_branch_name_from_reference('refs/heads/master') == 'master'
	assert get_branch_name_from_reference('refs/heads/main') == 'main'
	assert get_branch_name_from_reference('refs/heads/fix-110') == 'fix-110'
}

fn test_split_command_keeps_quoted_arguments() {
	assert split_command('--no-pager log main --pretty="%h %s"')! == ['--no-pager', 'log', 'main',
		'--pretty=%h %s']
	assert split_command('archive v1.0 --format=zip --output="/tmp/release archive.zip"')! == [
		'archive',
		'v1.0',
		'--format=zip',
		'--output=/tmp/release archive.zip',
	]
}

fn test_split_command_preserves_empty_arguments_and_literal_backslashes() {
	assert split_command(r'config key "" C:\repos\project trailing\')! == [
		'config',
		'key',
		'',
		r'C:\repos\project',
		r'trailing\',
	]
	assert split_command(r"show 'C:\path with spaces\file.txt'")! == [
		'show',
		r'C:\path with spaces\file.txt',
	]
}

fn test_split_command_rejects_unterminated_quotes() {
	mut rejected := false
	split_command('log "unterminated') or { rejected = true }
	assert rejected
}

fn test_parse_receive_updates_reads_every_ref() {
	old := '1'.repeat(40)
	new := '2'.repeat(40)
	zero := '0'.repeat(40)
	body := write_packet('${old} ${new} refs/heads/feature\0report-status side-band-64k') +
		write_packet('${new} ${zero} refs/heads/release/old') + flush_packet() + 'PACK'
	updates := parse_receive_updates(body)!
	assert updates.len == 2
	assert updates[0].branch_name() or { '' } == 'feature'
	assert !updates[0].is_delete()
	assert updates[1].branch_name() or { '' } == 'release/old'
	assert updates[1].is_delete()
	assert parse_branch_name_from_receive_upload(body) or { '' } == 'feature'
}

fn test_parse_receive_updates_rejects_truncated_or_invalid_commands() {
	mut rejected_truncated := false
	parse_receive_updates('9999short') or { rejected_truncated = true }
	assert rejected_truncated
	bad := write_packet('${'g'.repeat(40)} ${'2'.repeat(40)} refs/heads/main') + flush_packet()
	mut rejected_invalid := false
	parse_receive_updates(bad) or { rejected_invalid = true }
	assert rejected_invalid

	old := '1'.repeat(40)
	new := '2'.repeat(40)
	mut rejected_missing_flush := false
	parse_receive_updates(write_packet('${old} ${new} refs/heads/main')) or {
		rejected_missing_flush = true
	}
	assert rejected_missing_flush

	mut rejected_extra_field := false
	parse_receive_updates(write_packet('${old} ${new} refs/heads/main unexpected') + flush_packet()) or {
		rejected_extra_field = true
	}
	assert rejected_extra_field
}

fn test_receive_updates_are_only_accepted_after_successful_report_status() {
	assert receive_updates_accepted('0010unpack ok\n0018ok refs/heads/main\n0000')
	assert !receive_updates_accepted('0010unpack ok\n0028ng refs/heads/main hook declined\n0000')
	assert !receive_updates_accepted('0010unpack ok\n0000')
	assert !receive_updates_accepted('fatal: text happened to mention unpack ok')
	assert !receive_updates_accepted('')
}

fn test_git_ref_delete_requires_a_full_object_id() {
	assert GitRefUpdate{
		new_hash: '0'.repeat(40)
	}.is_delete()
	assert GitRefUpdate{
		new_hash: '0'.repeat(64)
	}.is_delete()
	assert !GitRefUpdate{
		new_hash: '000'
	}.is_delete()
}

fn test_git_info_refs_url_preserves_git_suffix() {
	assert git_info_refs_url('https://example.com/owner/repo.git') == 'https://example.com/owner/repo.git/info/refs?service=git-upload-pack'
	assert git_info_refs_url('https://example.com/owner/repo/') == 'https://example.com/owner/repo/info/refs?service=git-upload-pack'
}
