module git

fn test_parse_git_branch_output() {
	branch_name := parse_git_branch_output('* main')

	assert branch_name == 'main'
	assert parse_git_branch_output('  feature/nested') == 'feature/nested'
	assert parse_git_branch_output('') == ''
	assert parse_git_branch_output('*') == ''
	assert parse_git_branch_output('* (HEAD detached at abc1234)') == ''
	assert parse_git_branch_output('remotes/origin/HEAD -> origin/main') == ''
}
