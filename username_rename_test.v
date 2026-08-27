module main

import config
import os
import time

fn username_rename_test_app(root string) !&App {
	conf := config.Config{
		repo_storage_path: os.join_path(root, 'repos')
		archive_path:      os.join_path(root, 'archives')
		avatars_path:      os.join_path(root, 'avatars')
		sqlite:            config.SqliteConfig{
			path: os.join_path(root, 'gitly.sqlite')
		}
	}
	os.mkdir_all(conf.repo_storage_path)!
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	return app
}

fn add_username_rename_fixture(mut app App, user_id int, username string, repo_id int) !string {
	app.add_user(User{
		id:            user_id
		username:      username
		created_at:    time.now()
		is_registered: true
	})!
	repo_dir := os.join_path(app.config.repo_storage_path, username, 'project')
	os.mkdir_all(repo_dir)!
	os.write_file(os.join_path(repo_dir, 'marker'), 'repository data')!
	app.add_repo(Repo{
		id:             repo_id
		user_id:        user_id
		user_name:      username
		name:           'project'
		git_dir:        repo_dir
		primary_branch: 'main'
	})!
	return repo_dir
}

fn test_username_rename_moves_repositories_and_updates_every_path_atomically() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_username_rename_${os.getpid()}')
		os.rmdir_all(root) or {}
		defer {
			os.rmdir_all(root) or {}
		}
		mut app := username_rename_test_app(root)!
		defer {
			app.db.close() or {}
		}
		old_repo_dir := add_username_rename_fixture(mut app, 1, 'alice', 1)!

		app.rename_user_account(1, 'alice', 'bob')!

		user := app.get_user_by_id(1) or { panic('renamed user missing') }
		assert user.username == 'bob'
		assert user.namechanges_count == 1
		assert user.last_namechange_time > 0
		repo := app.find_repo_by_name_and_username('project', 'bob') or {
			panic('renamed repository missing')
		}
		expected_repo_dir := os.join_path(app.config.repo_storage_path, 'bob', 'project')
		assert repo.git_dir == expected_repo_dir
		assert !os.exists(old_repo_dir)
		assert os.read_file(os.join_path(expected_repo_dir, 'marker'))! == 'repository data'
	} $else {
		assert true
	}
}

fn test_username_rename_rolls_back_database_and_directory_on_failure() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_username_rename_rollback_${os.getpid()}')
		os.rmdir_all(root) or {}
		defer {
			os.rmdir_all(root) or {}
		}
		mut app := username_rename_test_app(root)!
		defer {
			app.db.close() or {}
		}
		old_repo_dir := add_username_rename_fixture(mut app, 2, 'carol', 2)!
		app.db.exec('create trigger reject_username_rename before update of username on ${sql_table('User')}
			when old.id = 2 begin select raise(abort, \'forced rename failure\'); end')!

		mut failed := false
		app.rename_user_account(2, 'carol', 'diana') or { failed = true }
		assert failed
		assert (app.get_user_by_id(2) or { panic('original user missing') }).username == 'carol'
		repo := app.find_repo_by_name_and_username('project', 'carol') or {
			panic('original repository missing')
		}
		assert repo.git_dir == old_repo_dir
		assert os.exists(os.join_path(old_repo_dir, 'marker'))
		assert !os.exists(os.join_path(app.config.repo_storage_path, 'diana'))
	} $else {
		assert true
	}
}
