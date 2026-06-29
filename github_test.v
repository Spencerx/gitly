module main

fn assert_github_owner_repo(url string, expected_owner string, expected_repo string) {
	owner, repo := parse_github_owner_repo(url) or {
		assert false
		return
	}
	assert owner == expected_owner
	assert repo == expected_repo
}

fn test_parse_github_owner_repo_accepts_common_clone_url_forms() {
	assert_github_owner_repo('https://github.com/vlang/gitly', 'vlang', 'gitly')
	assert_github_owner_repo('https://github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('http://github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('https://www.github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('git@github.com:vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('ssh://git@github.com/vlang/gitly.git', 'vlang', 'gitly')
}

fn test_parse_github_owner_repo_is_case_insensitive_for_protocol_and_host() {
	assert_github_owner_repo('HTTPS://GitHub.com/VLang/Gitly.git', 'VLang', 'Gitly')
	assert_github_owner_repo('https://WWW.GITHUB.COM/vlang/gitly.git', 'vlang', 'gitly')
}

fn test_parse_github_owner_repo_rejects_non_github_hosts() {
	assert !is_github_clone_url('https://example.com/vlang/gitly.git')
	assert !is_github_clone_url('https://github.com.evil.test/vlang/gitly.git')
	assert !is_github_clone_url('https://example.com/github.com/vlang/gitly.git')
}
