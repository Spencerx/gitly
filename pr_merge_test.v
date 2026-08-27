module main

import git
import os

fn must_git(args []string) string {
	r := git.Git.exec(args)
	if r.exit_code != 0 {
		panic('git ${args} failed: ${r.output}')
	}
	return r.output.trim_space()
}

fn test_squash_branches_in_bare_creates_single_parent_commit() {
	tmp_dir := os.join_path(os.temp_dir(), 'gitly_squash_pr_test_${os.getpid()}')
	os.rmdir_all(tmp_dir) or {}
	os.mkdir_all(tmp_dir)!
	defer {
		os.rmdir_all(tmp_dir) or {}
	}

	work_dir := os.join_path(tmp_dir, 'work')
	bare_dir := os.join_path(tmp_dir, 'repo.git')
	must_git(['init', work_dir])
	must_git(['-C', work_dir, 'checkout', '-b', 'main'])
	must_git(['-C', work_dir, 'config', 'user.name', 'Test User'])
	must_git(['-C', work_dir, 'config', 'user.email', 'test@example.com'])
	os.write_file(os.join_path(work_dir, 'file.txt'), 'base\n')!
	must_git(['-C', work_dir, 'add', 'file.txt'])
	must_git(['-C', work_dir, 'commit', '-m', 'base'])
	base_sha := must_git(['-C', work_dir, 'rev-parse', 'main'])

	must_git(['-C', work_dir, 'checkout', '-b', 'feature'])
	os.write_file(os.join_path(work_dir, 'file.txt'), 'feature\n')!
	must_git(['-C', work_dir, 'commit', '-am', 'feature change'])
	feature_sha := must_git(['-C', work_dir, 'rev-parse', 'feature'])

	must_git(['init', '--bare', bare_dir])
	must_git(['-C', work_dir, 'remote', 'add', 'origin', bare_dir])
	must_git(['-C', work_dir, 'push', 'origin', 'main', 'feature'])

	repo := Repo{
		git_dir: bare_dir
	}
	squash_sha := squash_branches_in_bare_at_head(repo, 'main', 'feature', feature_sha, 'tester',
		'Squash pull request #1')!

	assert must_git(['-C', bare_dir, 'rev-parse', 'main']) == squash_sha
	parent_line := must_git(['-C', bare_dir, 'rev-list', '--parents', '-n', '1', 'main'])
	parent_parts := parent_line.fields()
	assert parent_parts.len == 2
	assert parent_parts[1] == base_sha
	assert must_git(['-C', bare_dir, 'show', 'main:file.txt']) == 'feature'
	assert feature_sha !in must_git(['-C', bare_dir, 'rev-list', 'main']).split_into_lines()
}

fn test_expected_old_ref_update_does_not_overwrite_concurrent_change() {
	tmp_dir := os.join_path(os.temp_dir(), 'gitly_atomic_ref_test_${os.getpid()}')
	os.rmdir_all(tmp_dir) or {}
	os.mkdir_all(tmp_dir)!
	defer {
		os.rmdir_all(tmp_dir) or {}
	}

	work_dir := os.join_path(tmp_dir, 'work')
	bare_dir := os.join_path(tmp_dir, 'repo.git')
	must_git(['init', '-b', 'main', work_dir])
	must_git(['-C', work_dir, 'config', 'user.name', 'Test User'])
	must_git(['-C', work_dir, 'config', 'user.email', 'test@example.com'])
	os.write_file(os.join_path(work_dir, 'file.txt'), 'base\n')!
	must_git(['-C', work_dir, 'add', 'file.txt'])
	must_git(['-C', work_dir, 'commit', '-m', 'base'])
	base_sha := must_git(['-C', work_dir, 'rev-parse', 'HEAD'])

	must_git(['-C', work_dir, 'checkout', '-b', 'candidate'])
	os.write_file(os.join_path(work_dir, 'candidate.txt'), 'candidate\n')!
	must_git(['-C', work_dir, 'add', 'candidate.txt'])
	must_git(['-C', work_dir, 'commit', '-m', 'candidate'])
	candidate_sha := must_git(['-C', work_dir, 'rev-parse', 'HEAD'])
	must_git(['-C', work_dir, 'checkout', 'main'])
	os.write_file(os.join_path(work_dir, 'concurrent.txt'), 'concurrent\n')!
	must_git(['-C', work_dir, 'add', 'concurrent.txt'])
	must_git(['-C', work_dir, 'commit', '-m', 'concurrent'])
	concurrent_sha := must_git(['-C', work_dir, 'rev-parse', 'HEAD'])

	must_git(['init', '--bare', bare_dir])
	must_git(['-C', work_dir, 'remote', 'add', 'origin', bare_dir])
	must_git(['-C', work_dir, 'push', 'origin', 'main', 'candidate'])
	mut rejected := false
	update_git_ref_expected(bare_dir, 'refs/heads/main', candidate_sha, base_sha) or {
		rejected = true
	}
	assert rejected
	assert must_git(['-C', bare_dir, 'rev-parse', 'main']) == concurrent_sha
}
