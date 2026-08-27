module main

import git
import os

fn slash_ref_git(repo_dir string, args []string) string {
	result := git.Git.exec_in_dir(repo_dir, args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn create_slash_ref_repo(repo_dir string, with_commit bool) {
	os.rmdir_all(repo_dir) or {}
	os.mkdir_all(repo_dir) or { panic(err) }
	slash_ref_git(repo_dir, ['init', '-b', 'main'])
	if !with_commit {
		return
	}
	slash_ref_git(repo_dir, ['config', 'user.name', 'Ref Test'])
	slash_ref_git(repo_dir, ['config', 'user.email', 'ref-test@example.com'])
	os.mkdir_all(os.join_path(repo_dir, 'src')) or { panic(err) }
	os.write_file(os.join_path(repo_dir, 'README.md'), 'hello\n') or { panic(err) }
	os.write_file(os.join_path(repo_dir, 'src', 'main.v'), 'fn main() {}\n') or { panic(err) }
	slash_ref_git(repo_dir, ['add', '.'])
	slash_ref_git(repo_dir, ['commit', '-m', 'initial'])
	slash_ref_git(repo_dir, ['branch', 'feature/api'])
	slash_ref_git(repo_dir, ['tag', 'release/v1'])
	slash_ref_git(repo_dir, ['tag', 'feature/api'])
}

fn test_resolve_repo_ref_path_supports_slash_branches_tags_and_hashes() {
	repo_dir := os.join_path(os.temp_dir(), 'gitly_slash_ref_${os.getpid()}')
	create_slash_ref_repo(repo_dir, true)
	defer {
		os.rmdir_all(repo_dir) or {}
	}
	repo := Repo{
		git_dir:        repo_dir
		primary_branch: 'main'
	}

	branch_root := resolve_repo_ref_path(repo, 'feature/api', false) or {
		panic('slash branch did not resolve')
	}
	assert branch_root.ref_name == 'feature/api'
	assert branch_root.path == ''

	branch_file := resolve_repo_ref_path(repo, 'feature/api/src/main.v', true) or {
		panic('file below slash branch did not resolve')
	}
	assert branch_file.ref_name == 'feature/api'
	assert branch_file.path == 'src/main.v'

	tag_file := resolve_repo_ref_path(repo, 'release/v1/README.md', true) or {
		panic('file below slash tag did not resolve')
	}
	assert tag_file.ref_name == 'refs/tags/release/v1'
	assert tag_file.path == 'README.md'

	// Short ambiguous names select the branch. The fully-qualified spelling is
	// the stable way to select a same-named tag.
	ambiguous := resolve_repo_ref_path(repo, 'feature/api/README.md', true) or {
		panic('ambiguous short ref did not resolve')
	}
	assert ambiguous.ref_name == 'feature/api'
	explicit_tag := resolve_repo_ref_path(repo, 'refs/tags/feature/api/README.md', true) or {
		panic('explicit same-named tag did not resolve')
	}
	assert explicit_tag.ref_name == 'refs/tags/feature/api'
	assert explicit_tag.path == 'README.md'

	hash := slash_ref_git(repo_dir, ['rev-parse', 'HEAD'])
	hash_file := resolve_repo_ref_path(repo, '${hash}/README.md', true) or {
		panic('file below commit hash did not resolve')
	}
	assert hash_file.ref_name == hash
	assert hash_file.path == 'README.md'

	if _ := resolve_repo_ref_path(repo, 'missing/ref/README.md', true) {
		assert false, 'unknown refs must not resolve'
	}
	if _ := resolve_repo_ref_path(repo, 'feature/api/../secret', false) {
		assert false, 'unsafe repository paths must not resolve'
	}
}

fn test_resolve_repo_ref_path_allows_only_unborn_default_branch_root() {
	repo_dir := os.join_path(os.temp_dir(), 'gitly_unborn_ref_${os.getpid()}')
	create_slash_ref_repo(repo_dir, false)
	defer {
		os.rmdir_all(repo_dir) or {}
	}
	repo := Repo{
		git_dir:        repo_dir
		primary_branch: 'main'
	}

	root := resolve_repo_ref_path(repo, 'main', false) or {
		panic('unborn default branch did not resolve')
	}
	assert root.ref_name == 'main'
	assert root.path == ''
	if _ := resolve_repo_ref_path(repo, 'main/README.md', false) {
		assert false, 'unborn branch paths must not resolve'
	}
	if _ := resolve_repo_ref_path(repo, 'other', false) {
		assert false, 'unknown unborn branch must not resolve'
	}
}
