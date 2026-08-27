module main

import config
import os

fn repo_transfer_test_app(suffix string) !(&App, string) {
	root := os.join_path(os.temp_dir(), 'gitly_transfer_${os.getpid()}_${suffix}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root)!
	conf := config.Config{
		repo_storage_path: root
		archive_path:      root
		avatars_path:      root
		sqlite:            config.SqliteConfig{
			path: os.join_path(root, 'test.sqlite')
		}
	}
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	return app, root
}

fn cleanup_repo_transfer_test(mut app App, root string) {
	app.db.close() or {}
	os.rmdir_all(root) or {}
}

fn test_repo_transfer_replacement_is_single_and_validated() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_transfer_${os.getpid()}.sqlite')
		os.rm(db_path) or {}
		conf := config.Config{
			sqlite: config.SqliteConfig{
				path: db_path
			}
		}
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		app.create_tables()!

		mut rejected := false
		app.request_repo_transfer(0, 1, 2) or { rejected = true }
		assert rejected

		app.request_repo_transfer(7, 1, 2)!
		app.request_repo_transfer(7, 1, 3)!
		target_repo_id := 7
		transfers := sql app.db {
			select from RepoTransfer where repo_id == target_repo_id
		}!
		assert transfers.len == 1
		assert transfers[0].requested_by == 1
		assert transfers[0].recipient_id == 3

		// The replacement uses the same transaction handle for every ORM call.
		// Rolling it back must restore the previous request in full.
		mut tx := db_begin_transaction(mut app.db)!
		sql tx {
			delete from RepoTransfer where repo_id == target_repo_id
		}!
		replacement := RepoTransfer{
			repo_id:      target_repo_id
			requested_by: 1
			recipient_id: 4
			created_at:   1
		}
		sql tx {
			insert replacement into RepoTransfer
		}!
		tx.rollback()!
		after_rollback := sql app.db {
			select from RepoTransfer where repo_id == target_repo_id
		}!
		assert after_rollback.len == 1
		assert after_rollback[0].recipient_id == 3
	} $else {
		assert true
	}
}

fn test_repo_transfer_rechecks_revoked_organization_owner_under_claim() {
	$if sqlite ? {
		mut app, root := repo_transfer_test_app('revoked')!
		defer {
			cleanup_repo_transfer_test(mut app, root)
		}
		app.add_user(User{
			username:      'requester'
			is_registered: true
		})!
		app.add_user(User{
			username:      'recipient'
			is_registered: true
		})!
		requester := app.get_user_by_username('requester') or { panic('requester missing') }
		recipient := app.get_user_by_username('recipient') or { panic('recipient missing') }
		org_id := app.add_org('team', 'team@example.com', 'organization', requester.id)!
		app.add_org_member(org_id, requester.id, 'admin')!
		repo_dir := os.join_path(root, 'team', 'project')
		os.mkdir_all(repo_dir)!
		app.add_repo(Repo{
			git_dir:        repo_dir
			name:           'project'
			user_id:        requester.id
			user_name:      'team'
			primary_branch: 'main'
		})!
		repo := app.find_repo_by_name_and_username('project', 'team') or { panic('repo missing') }
		app.request_repo_transfer(repo.id, requester.id, recipient.id)!
		target_repo_id := repo.id
		transfers := sql app.db {
			select from RepoTransfer where repo_id == target_repo_id limit 1
		}!
		assert transfers.len == 1
		target_transfer_id := transfers[0].id

		app.remove_org_member(org_id, requester.id)!
		mut rejected := false
		app.accept_repo_transfer_atomic(target_transfer_id, recipient.id) or { rejected = true }
		assert rejected
		unchanged := app.find_repo_by_name_and_username('project', 'team') or {
			panic('revoked transfer moved repository')
		}
		assert unchanged.user_id == requester.id
		assert unchanged.git_dir == repo_dir
		assert os.exists(repo_dir)
		remaining := sql app.db {
			select count from RepoTransfer where id == target_transfer_id
		}!
		assert remaining == 0
	} $else {
		assert true
	}
}

fn test_repo_transfer_restores_filesystem_and_database_when_update_fails() {
	$if sqlite ? {
		mut app, root := repo_transfer_test_app('rollback')!
		defer {
			cleanup_repo_transfer_test(mut app, root)
		}
		app.add_user(User{
			username:      'source'
			is_registered: true
		})!
		app.add_user(User{
			username:      'destination'
			is_registered: true
		})!
		source := app.get_user_by_username('source') or { panic('source missing') }
		destination := app.get_user_by_username('destination') or { panic('destination missing') }
		source_path := os.join_path(root, source.username, 'project')
		os.mkdir_all(source_path)!
		app.add_repo(Repo{
			git_dir:        source_path
			name:           'project'
			user_id:        source.id
			user_name:      source.username
			primary_branch: 'main'
		})!
		repo := app.find_repo_by_name_and_username('project', source.username) or {
			panic('repo missing')
		}
		app.request_repo_transfer(repo.id, source.id, destination.id)!
		target_repo_id := repo.id
		transfers := sql app.db {
			select from RepoTransfer where repo_id == target_repo_id limit 1
		}!
		assert transfers.len == 1
		target_transfer_id := transfers[0].id
		app.db.exec('create trigger fail_repo_transfer before update of user_id on ${sql_table('Repo')}
			when new.user_id != old.user_id begin select raise(abort, \'forced transfer failure\'); end')!

		mut failed := false
		app.accept_repo_transfer_atomic(target_transfer_id, destination.id) or { failed = true }
		assert failed
		assert os.exists(source_path)
		assert !os.exists(os.join_path(root, destination.username, repo.name))
		unchanged := app.find_repo_by_name_and_username(repo.name, source.username) or {
			panic('repository ownership changed despite rollback')
		}
		assert unchanged.git_dir == source_path
		remaining := sql app.db {
			select count from RepoTransfer where id == target_transfer_id
		}!
		assert remaining == 1
	} $else {
		assert true
	}
}
