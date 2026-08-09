module main

import os
import config
import git

fn transport_test_app(root string) !(&App, string) {
	db_path := os.join_path(root, 'transport.sqlite')
	conf := config.Config{
		repo_storage_path:        os.join_path(root, 'repos')
		archive_path:             root
		avatars_path:             root
		storage_secret:           'transport-test-secret-that-is-long-enough'
		ssh_enabled:              true
		ssh_hostname:             'git.example.test'
		ssh_port:                 2222
		ssh_user:                 'git'
		ssh_authorized_keys_path: os.join_path(root, 'authorized_keys')
		sqlite:                   config.SqliteConfig{
			path: db_path
		}
	}
	os.mkdir_all(conf.repo_storage_path)!
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	return app, db_path
}

fn transport_git(args []string) string {
	result := git.Git.exec(args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn transport_commit(work string, content string, message string) string {
	os.write_file(os.join_path(work, 'README.md'), content) or { panic(err) }
	transport_git(['-C', work, 'add', 'README.md'])
	transport_git(['-C', work, 'commit', '-m', message])
	return transport_git(['-C', work, 'rev-parse', 'HEAD'])
}

fn initialize_transport_origin(root string) !(string, string) {
	bare := os.join_path(root, 'source.git')
	work := os.join_path(root, 'source-work')
	transport_git(['init', '--bare', bare])
	transport_git(['init', '-b', 'main', work])
	transport_git(['-C', work, 'config', 'user.name', 'Transport Test'])
	transport_git(['-C', work, 'config', 'user.email', 'transport@example.test'])
	transport_git(['-C', work, 'remote', 'add', 'origin', bare])
	transport_commit(work, 'initial\n', 'initial')
	transport_git(['-C', work, 'push', '-u', 'origin', 'main'])
	transport_git(['-C', bare, 'symbolic-ref', 'HEAD', 'refs/heads/main'])
	return bare, work
}

fn insert_transport_user(mut app App, id int, username string) ! {
	row := User{
		id:            id
		username:      username
		is_registered: true
	}
	sql app.db {
		insert row into User
	}!
}

fn test_forks_track_lineage_and_only_fast_forward_from_upstream() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_fork_transport_${os.getpid()}')
		os.rmdir_all(root) or {}
		os.mkdir_all(root)!
		mut app, db_path := transport_test_app(root)!
		defer {
			app.db.close() or {}
			os.rmdir_all(root) or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		bare, work := initialize_transport_origin(root)!
		insert_transport_user(mut app, 1, 'alice')!
		insert_transport_user(mut app, 2, 'bob')!
		app.add_repo(Repo{
			id:             1
			git_dir:        bare
			name:           'project'
			user_id:        1
			user_name:      'alice'
			is_public:      true
			primary_branch: 'main'
			status:         .done
		})!
		source := app.find_repo_by_id(1) or { panic('source missing') }
		created := app.create_fork(source, 'bob', 2, 'project', 'fork', true, false, 2)!
		relation := app.find_fork_by_repo(created.id) or { panic('fork relationship missing') }
		assert relation.source_repo_id == source.id
		assert relation.root_repo_id == source.id
		assert app.count_repo_forks(source.id) == 1
		assert transport_git(['-C', created.git_dir, 'remote', 'get-url', 'upstream']) == bare

		second := transport_commit(work, 'second\n', 'second')
		transport_git(['-C', work, 'push', 'origin', 'main'])
		first_sync := app.sync_fork(created, relation, false)!
		assert first_sync.updated.contains('main')
		assert transport_git(['-C', created.git_dir, 'rev-parse', 'main']) == second

		fork_work := os.join_path(root, 'fork-work')
		transport_git(['clone', created.git_dir, fork_work])
		transport_git(['-C', fork_work, 'config', 'user.name', 'Fork User'])
		transport_git(['-C', fork_work, 'config', 'user.email', 'fork@example.test'])
		transport_commit(fork_work, 'fork change\n', 'fork change')
		transport_git(['-C', fork_work, 'push', 'origin', 'main'])
		transport_commit(work, 'upstream change\n', 'upstream change')
		transport_git(['-C', work, 'push', 'origin', 'main'])
		diverged := app.sync_fork(created, relation, false)!
		assert diverged.skipped.contains('main')
		assert transport_git(['-C', created.git_dir, 'rev-parse', 'main']) != transport_git([
			'-C',
			bare,
			'rev-parse',
			'main',
		])
	} $else {
		assert true
	}
}

fn test_ssh_keys_generate_managed_authorized_keys_and_clone_url() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_ssh_transport_${os.getpid()}')
		os.rmdir_all(root) or {}
		os.mkdir_all(root)!
		mut app, db_path := transport_test_app(root)!
		defer {
			app.db.close() or {}
			os.rmdir_all(root) or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		insert_transport_user(mut app, 1, 'alice')!
		key := 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTp8P3nHx3Eu0PUM1Op46RGvl/9Ln+w8pqoW5b+RF9y test@example'
		app.add_ssh_key(1, 'Laptop', key, 'auth', 0)!
		managed := os.read_file(app.config.ssh_authorized_keys_path)!
		assert managed.contains(ssh_authorized_keys_begin)
		assert managed.contains('restrict,command=')
		assert managed.contains('ssh-shell')
		assert managed.contains('user')
		assert managed.contains(normalized_ssh_public_key(key) or { '' })
		keys := app.find_ssh_keys(1)
		assert keys.len == 1
		assert keys[0].fingerprint.starts_with('SHA256:')
		assert app.generate_ssh_clone_url(Repo{
			user_name: 'alice'
			name:      'project'
		}) == 'ssh://git@git.example.test:2222/alice/project.git'
	} $else {
		assert true
	}
}

fn test_deploy_key_write_access_does_not_bypass_protected_branches_by_default() {
	assert deploy_key_access_level(DeployKey{}) == project_access_reporter
	assert deploy_key_access_level(DeployKey{
		can_push: true
	}) == project_access_developer
	assert deploy_key_access_level(DeployKey{
		can_push:           true
		can_push_protected: true
	}) == project_access_owner
}

fn test_mirror_credentials_use_authenticated_encryption() {
	secret := 'a-long-storage-secret-for-tests'
	ciphertext := encrypt_mirror_secret(secret, 'sensitive-token')!
	assert ciphertext != 'sensitive-token'
	assert !ciphertext.contains('sensitive-token')
	assert decrypt_mirror_secret(secret, ciphertext)! == 'sensitive-token'
	mut tampered := ciphertext.bytes()
	tampered[tampered.len - 2] = if tampered[tampered.len - 2] == `A` { `B` } else { `A` }
	mut rejected := false
	decrypt_mirror_secret(secret, tampered.bytestr()) or { rejected = true }
	assert rejected
}

fn test_ssh_mirror_endpoint_requires_pinned_auth_material() {
	clean, username, password, scheme := normalize_mirror_endpoint('ssh://git@localhost/team/project.git', [
		'localhost',
	])!
	assert clean == 'ssh://git@localhost/team/project.git'
	assert username == 'git'
	assert password == ''
	assert scheme == 'ssh'
	assert is_safe_mirror_endpoint(clean, ['localhost'])
	assert !is_safe_mirror_endpoint(clean, [])
}

fn test_cross_fork_merge_request_refreshes_head_and_invalidates_approvals() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_cross_fork_pr_${os.getpid()}')
		os.rmdir_all(root) or {}
		os.mkdir_all(root)!
		mut app, db_path := transport_test_app(root)!
		defer {
			app.db.close() or {}
			os.rmdir_all(root) or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		bare, _ := initialize_transport_origin(root)!
		insert_transport_user(mut app, 1, 'alice')!
		insert_transport_user(mut app, 2, 'bob')!
		insert_transport_user(mut app, 3, 'reviewer')!
		app.add_repo(Repo{
			id:             1
			git_dir:        bare
			name:           'project'
			user_id:        1
			user_name:      'alice'
			is_public:      true
			primary_branch: 'main'
			status:         .done
		})!
		source := app.find_repo_by_id(1) or { panic('source missing') }
		created := app.create_fork(source, 'bob', 2, 'project', 'fork', true, false, 2)!
		fork_work := os.join_path(root, 'feature-work')
		transport_git(['clone', created.git_dir, fork_work])
		transport_git(['-C', fork_work, 'config', 'user.name', 'Fork User'])
		transport_git(['-C', fork_work, 'config', 'user.email', 'fork@example.test'])
		transport_git(['-C', fork_work, 'checkout', '-b', 'feature'])
		feature_sha := transport_commit(fork_work, 'feature\n', 'feature')
		transport_git(['-C', fork_work, 'push', 'origin', 'feature'])
		mut refreshed_fork := created
		app.update_repo_from_fs(mut refreshed_fork, false)!

		pr_id := app.add_pull_request_from_repo(source.id, created.id, 2, 'Feature', '', 'feature',
			'main')!
		pr := app.find_pull_request_by_id(pr_id) or { panic('PR missing') }
		app.refresh_cross_fork_pr_head(source, pr)!
		assert transport_git(['-C', source.git_dir, 'rev-parse', pr.head_ref()]) == feature_sha
		assert source.list_commits_between('main', pr.head_ref()).len == 1

		app.add_project_member(source.id, 3, 'developer')!
		app.approve_pull_request(pr.id, 3)!
		assert app.pull_request_approval_count(pr.id) == 1
		app.clear_open_pr_approvals_for_head(created.id, 'feature')!
		assert app.pull_request_approval_count(pr.id) == 0
		merge_sha := merge_branches_in_bare(source, 'main', pr.head_ref(), 'Reviewer', 'merge')!
		assert transport_git(['-C', source.git_dir, 'rev-parse', 'main']) == merge_sha
	} $else {
		assert true
	}
}

fn test_local_push_and_pull_mirror_ref_updates() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_mirror_transport_${os.getpid()}')
		os.rmdir_all(root) or {}
		os.mkdir_all(root)!
		mut app, db_path := transport_test_app(root)!
		defer {
			app.db.close() or {}
			os.rmdir_all(root) or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		source_bare, source_work := initialize_transport_origin(root)!
		insert_transport_user(mut app, 1, 'alice')!
		app.add_repo(Repo{
			id:             1
			git_dir:        source_bare
			name:           'source'
			user_id:        1
			user_name:      'alice'
			is_public:      true
			primary_branch: 'main'
			status:         .done
		})!
		push_target := os.join_path(root, 'push-target.git')
		transport_git(['init', '--bare', push_target])
		push_mirror := RepoMirror{
			id:                 1
			repo_id:            1
			created_by:         1
			direction:          'push'
			url:                push_target
			enabled:            true
			overwrite_diverged: true
			interval_minutes:   5
		}
		sql app.db {
			insert push_mirror into RepoMirror
		}!
		app.sync_repo_mirror(push_mirror, true)!
		assert transport_git(['-C', push_target, 'rev-parse', 'refs/heads/main']) == transport_git([
			'-C',
			source_bare,
			'rev-parse',
			'refs/heads/main',
		])

		pull_target := os.join_path(root, 'pull-target.git')
		transport_git(['init', '--bare', pull_target])
		app.add_repo(Repo{
			id:             2
			git_dir:        pull_target
			name:           'pull-target'
			user_id:        1
			user_name:      'alice'
			is_public:      true
			primary_branch: 'main'
			status:         .done
		})!
		new_head := transport_commit(source_work, 'mirror update\n', 'mirror update')
		transport_git(['-C', source_work, 'push', 'origin', 'main'])
		pull_mirror := RepoMirror{
			id:               2
			repo_id:          2
			created_by:       1
			direction:        'pull'
			url:              source_bare
			enabled:          true
			interval_minutes: 5
		}
		sql app.db {
			insert pull_mirror into RepoMirror
		}!
		app.sync_repo_mirror(pull_mirror, true)!
		assert transport_git(['-C', pull_target, 'rev-parse', 'refs/heads/main']) == new_head
	} $else {
		assert true
	}
}
