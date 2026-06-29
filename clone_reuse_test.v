module main

import git
import os

fn must_git_clone_reuse(args []string) string {
	res := git.Git.exec(args)
	if res.exit_code != 0 {
		panic('git ${args} failed: ${res.output}')
	}
	return res.output.trim_space()
}

fn test_same_clone_source_url_matches_github_forms() {
	assert same_clone_source_url('https://github.com/vlang/v.git', 'github.com/VLang/v')
	assert same_clone_source_url('https://www.github.com/vlang/v/', 'git@github.com:vlang/v.git')
	assert same_clone_source_url('https://example.com/team/repo.git',
		'https://example.com/team/repo/')
	assert !same_clone_source_url('https://example.com/Team/repo', 'https://example.com/team/repo')
}

fn test_clone_from_existing_fetches_latest_origin_branch() {
	tmp_dir := os.join_path(os.temp_dir(), 'gitly_clone_reuse_test_${os.getpid()}')
	os.rmdir_all(tmp_dir) or {}
	os.mkdir_all(tmp_dir)!
	defer {
		os.rmdir_all(tmp_dir) or {}
	}

	work_dir := os.join_path(tmp_dir, 'work')
	origin_dir := os.join_path(tmp_dir, 'origin.git')
	source_dir := os.join_path(tmp_dir, 'source.git')
	target_dir := os.join_path(tmp_dir, 'target.git')

	must_git_clone_reuse(['init', '--bare', origin_dir])
	must_git_clone_reuse(['init', work_dir])
	must_git_clone_reuse(['-C', work_dir, 'checkout', '-b', 'main'])
	must_git_clone_reuse(['-C', work_dir, 'config', 'user.name', 'Test User'])
	must_git_clone_reuse(['-C', work_dir, 'config', 'user.email', 'test@example.com'])
	os.write_file(os.join_path(work_dir, 'file.txt'), 'first\n')!
	must_git_clone_reuse(['-C', work_dir, 'add', 'file.txt'])
	must_git_clone_reuse(['-C', work_dir, 'commit', '-m', 'first'])
	must_git_clone_reuse(['-C', work_dir, 'remote', 'add', 'origin', origin_dir])
	must_git_clone_reuse(['-C', work_dir, 'push', 'origin', 'main'])
	must_git_clone_reuse(['-C', origin_dir, 'symbolic-ref', 'HEAD', 'refs/heads/main'])

	must_git_clone_reuse(['clone', '--bare', origin_dir, source_dir])
	os.write_file(os.join_path(work_dir, 'file.txt'), 'second\n')!
	must_git_clone_reuse(['-C', work_dir, 'commit', '-am', 'second'])
	must_git_clone_reuse(['-C', work_dir, 'push', 'origin', 'main'])
	latest_sha := must_git_clone_reuse(['-C', work_dir, 'rev-parse', 'main'])

	source_repo := Repo{
		git_dir:   source_dir
		name:      'source'
		user_name: 'alice'
	}
	mut target_repo := Repo{
		git_dir:        target_dir
		name:           'target'
		user_name:      'bob'
		clone_url:      origin_dir
		primary_branch: 'master'
	}

	assert target_repo.clone_from_existing(source_repo, false) == .reused
	assert target_repo.status == .done
	assert target_repo.primary_branch == 'main'
	assert repo_origin_url(target_dir) or { '' } == origin_dir
	assert must_git_clone_reuse(['-C', target_dir, 'rev-parse', 'main']) == latest_sha
	assert !os.exists(target_repo.clone_progress_path())
}
