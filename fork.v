// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import git

struct RepoFork {
	id              int @[primary; sql: serial]
	repo_id         int @[unique]
	source_repo_id  int
	root_repo_id    int
	created_by      int
	created_at      int
	last_sync_at    int
	last_sync_error string
}

struct ForkSyncResult {
mut:
	updated []string
	skipped []string
}

fn (app &App) find_fork_by_repo(repo_id int) ?RepoFork {
	rows := sql app.db {
		select from RepoFork where repo_id == repo_id limit 1
	} or { []RepoFork{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (app &App) find_repo_forks(source_repo_id int) []Repo {
	relations := sql app.db {
		select from RepoFork where source_repo_id == source_repo_id order by created_at desc
	} or { []RepoFork{} }
	mut repos := []Repo{cap: relations.len}
	for relation in relations {
		repo := app.find_repo_by_id(relation.repo_id) or { continue }
		if !repo.is_deleted {
			repos << repo
		}
	}
	return repos
}

fn (app &App) count_repo_forks(source_repo_id int) int {
	return sql app.db {
		select count from RepoFork where source_repo_id == source_repo_id
	} or { 0 }
}

fn (app &App) repo_fork_root_id(repo_id int) int {
	relation := app.find_fork_by_repo(repo_id) or { return repo_id }
	return if relation.root_repo_id > 0 { relation.root_repo_id } else { relation.source_repo_id }
}

fn (app &App) repos_share_fork_network(first_id int, second_id int) bool {
	return first_id > 0 && second_id > 0
		&& app.repo_fork_root_id(first_id) == app.repo_fork_root_id(second_id)
}

fn fetch_fork_branch_into(target Repo, source Repo, branch string, destination_ref string) ! {
	if !is_safe_ref(branch) || !destination_ref.starts_with('refs/')
		|| destination_ref.contains_any('\x00\r\n ') || destination_ref.contains('..') {
		return error('Invalid fork branch')
	}
	branch_exists := git.Git.exec_in_dir(source.git_dir, ['show-ref', '--verify', '--quiet',
		'refs/heads/${branch}'])
	if branch_exists.exit_code != 0 {
		return error('The source branch no longer exists')
	}
	fetch := git.Git.exec_in_dir(target.git_dir, ['fetch', '--no-tags', source.git_dir,
		'+refs/heads/${branch}:${destination_ref}'])
	if fetch.exit_code != 0 {
		return error('Could not fetch the fork branch')
	}
}

fn (app &App) refresh_cross_fork_pr_head(target Repo, pr PullRequest) ! {
	if pr.head_repo_id <= 0 || pr.head_repo_id == target.id {
		return
	}
	if !app.repos_share_fork_network(target.id, pr.head_repo_id) {
		return error('The merge request source is outside this fork network')
	}
	source := app.find_repo_by_id(pr.head_repo_id) or {
		return error('The source fork no longer exists')
	}
	fetch_fork_branch_into(target, source, pr.head_branch, pr.head_ref())!
}

fn (mut app App) delete_repo_fork_relationships(repo_id int) ! {
	sql app.db {
		delete from RepoFork where repo_id == repo_id || source_repo_id == repo_id
	}!
}

fn configure_fork_remote(path string, source Repo) ! {
	set_existing := git.Git.exec_in_dir(path, ['remote', 'set-url', 'upstream', source.git_dir])
	if set_existing.exit_code != 0 {
		rename := git.Git.exec_in_dir(path, ['remote', 'rename', 'origin', 'upstream'])
		if rename.exit_code != 0 {
			add := git.Git.exec_in_dir(path, ['remote', 'add', 'upstream', source.git_dir])
			if add.exit_code != 0 {
				return error('Could not configure the fork upstream')
			}
		}
	}
	set_url := git.Git.exec_in_dir(path, ['remote', 'set-url', 'upstream', source.git_dir])
	if set_url.exit_code != 0 {
		return error('Could not configure the fork upstream')
	}
	fetch_config := git.Git.exec_in_dir(path, ['config', 'remote.upstream.fetch',
		'+refs/heads/*:refs/remotes/upstream/*'])
	if fetch_config.exit_code != 0 {
		return error('Could not configure upstream branch tracking')
	}
}

fn (mut app App) create_fork(source Repo, owner_name string, owner_user_id int, name string,
	description string, is_public bool, default_branch_only bool, created_by int) !Repo {
	if source.id <= 0 || source.status != .done || source.is_deleted || owner_name == ''
		|| owner_user_id <= 0 || created_by <= 0 {
		return error('The source repository is not available for forking')
	}
	owner_dir := os.join_path(app.config.repo_storage_path, owner_name)
	os.mkdir_all(owner_dir)!
	target_path := os.join_path(owner_dir, name)
	if os.exists(target_path) {
		return error('The destination repository already exists')
	}
	mut clone_args := ['clone', '--bare', '--no-hardlinks']
	if default_branch_only {
		clone_args << '--single-branch'
		clone_args << '--branch'
		clone_args << source.primary_branch
	}
	clone_args << source.git_dir
	clone_args << target_path
	clone_result := git.Git.exec(clone_args)
	if clone_result.exit_code != 0 {
		os.rmdir_all(target_path) or {}
		return error('Could not copy the source repository: ${clone_result.output.trim_space()}')
	}
	configure_fork_remote(target_path, source) or {
		os.rmdir_all(target_path) or {}
		return err
	}
	mut row := Repo{
		git_dir:             target_path
		name:                name
		user_id:             owner_user_id
		user_name:           owner_name
		description:         description
		is_public:           is_public && source.is_public
		primary_branch:      source.primary_branch
		created_at:          int(time.now().unix())
		status:              .done
		disable_discussions: source.disable_discussions
		disable_projects:    source.disable_projects
		disable_milestones:  source.disable_milestones
		disable_wiki:        source.disable_wiki
	}
	app.add_repo(row) or {
		os.rmdir_all(target_path) or {}
		return err
	}
	created := app.find_repo_by_name_and_username(name, owner_name) or {
		os.rmdir_all(target_path) or {}
		return error('Could not load the newly created fork')
	}
	source_relation := app.find_fork_by_repo(source.id) or { RepoFork{} }
	relation := RepoFork{
		repo_id:        created.id
		source_repo_id: source.id
		root_repo_id:   if source_relation.root_repo_id > 0 {
			source_relation.root_repo_id
		} else {
			source.id
		}
		created_by:     created_by
		created_at:     int(time.now().unix())
	}
	sql app.db {
		insert relation into RepoFork
	} or {
		id := created.id
		sql app.db {
			update Repo set is_deleted = true where id == id
		} or {}
		os.rmdir_all(target_path) or {}
		return err
	}
	app.update_repo_primary_branch(created.id, source.primary_branch) or {}
	row = created
	app.update_repo_from_fs(mut row, false) or {
		app.warn('Could not warm fork repository cache: ${err}')
	}
	return created
}

fn (mut app App) sync_fork(repo Repo, relation RepoFork, default_branch_only bool) !ForkSyncResult {
	if relation.repo_id != repo.id {
		return error('Invalid fork relationship')
	}
	source := app.find_repo_by_id(relation.source_repo_id) or {
		return error('The upstream repository no longer exists')
	}
	configure_fork_remote(repo.git_dir, source)!
	fetch := git.Git.exec_in_dir(repo.git_dir, ['fetch', '--prune', '--no-tags', 'upstream',
		'+refs/heads/*:refs/remotes/upstream/*'])
	if fetch.exit_code != 0 {
		app.record_fork_sync(relation.id, fetch.output.trim_space())
		return error('Could not fetch upstream: ${fetch.output.trim_space()}')
	}
	refs := git.Git.exec_in_dir(repo.git_dir, ['for-each-ref', '--format=%(refname:strip=3)',
		'refs/remotes/upstream'])
	if refs.exit_code != 0 {
		app.record_fork_sync(relation.id, refs.output.trim_space())
		return error('Could not inspect upstream branches')
	}
	mut result := ForkSyncResult{}
	for raw_branch in refs.output.split_into_lines() {
		branch := raw_branch.trim_space()
		if branch == '' || (default_branch_only && branch != repo.primary_branch) {
			continue
		}
		local_ref := 'refs/heads/${branch}'
		remote_ref := 'refs/remotes/upstream/${branch}'
		local_exists := git.Git.exec_in_dir(repo.git_dir, ['show-ref', '--verify', '--quiet',
			local_ref]).exit_code == 0
		if local_exists {
			ff := git.Git.exec_in_dir(repo.git_dir, ['merge-base', '--is-ancestor', local_ref,
				remote_ref])
			if ff.exit_code != 0 {
				result.skipped << branch
				continue
			}
		}
		update := git.Git.exec_in_dir(repo.git_dir, ['update-ref', local_ref, remote_ref])
		if update.exit_code == 0 {
			result.updated << branch
		} else {
			result.skipped << branch
		}
	}
	app.record_fork_sync(relation.id, '')
	mut refreshed := repo
	app.update_repo_from_fs(mut refreshed, false) or {
		return error('Branches synchronized, but the repository cache could not be refreshed')
	}
	return result
}

fn (mut app App) record_fork_sync(id int, message string) {
	now := int(time.now().unix())
	sql app.db {
		update RepoFork set last_sync_at = now, last_sync_error = message where id == id
	} or {}
}
