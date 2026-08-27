module main

import config
import crypto.sha256
import os
import time

fn git_http_auth_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_git_http_auth_${os.getpid()}.sqlite')
	os.rm(db_path) or {}
	conf := config.Config{
		repo_storage_path: os.temp_dir()
		archive_path:      os.temp_dir()
		avatars_path:      os.temp_dir()
		sqlite:            config.SqliteConfig{
			path: db_path
		}
	}
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	return app, db_path
}

fn insert_git_http_auth_test_user(mut app App, id int, username string, password string) ! {
	salt := 'salt-${id}'
	user := User{
		id:            id
		username:      username
		password:      sha256.sum('${password}${salt}'.bytes()).hex()
		salt:          salt
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
}

fn test_git_http_requires_same_user_pat_when_two_factor_is_enabled() {
	$if sqlite ? {
		mut app, db_path := git_http_auth_test_app()!
		defer {
			app.db.close() or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}

		insert_git_http_auth_test_user(mut app, 1, 'alice', 'alice-password')!
		insert_git_http_auth_test_user(mut app, 2, 'bob', 'bob-password')!
		_, alice_token := app.add_api_token(1, 'git')!
		_, bob_token := app.add_api_token(2, 'git')!
		alice := app.get_user_by_id(1) or { panic('alice missing') }

		// Passwords and PATs both remain valid before 2FA is enabled.
		assert app.git_http_credential_is_valid(alice, 'alice-password', false)
		assert app.git_http_credential_is_valid(alice, 'alice-password', true)
		assert app.git_http_credential_is_valid(alice, alice_token, false)
		assert app.git_http_credential_is_valid(alice, alice_token, true)
		assert !app.git_http_credential_is_valid(alice, bob_token, false)

		app.upsert_two_factor(alice.id, 'JBSWY3DPEHPK3PXP', true)!
		assert !app.git_http_credential_is_valid(alice, 'alice-password', false)
		assert !app.git_http_credential_is_valid(alice, 'alice-password', true)
		assert app.git_http_credential_is_valid(alice, alice_token, false)
		assert app.git_http_credential_is_valid(alice, alice_token, true)
		assert !app.git_http_credential_is_valid(alice, bob_token, true)
	} $else {
		assert true
	}
}

fn test_git_http_pat_scopes_distinguish_fetch_and_push() {
	$if sqlite ? {
		mut app, db_path := git_http_auth_test_app()!
		defer {
			app.db.close() or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}

		insert_git_http_auth_test_user(mut app, 1, 'alice', 'alice-password')!
		alice := app.get_user_by_id(1) or { panic('alice missing') }
		expires_at := int(time.now().unix()) + 3600
		_, read_token := app.add_scoped_api_token(1, 'fetch', [
			api_token_scope_read_repository,
		], expires_at)!
		_, write_token := app.add_scoped_api_token(1, 'push', [
			api_token_scope_write_repository,
		], expires_at)!
		_, read_api_token := app.add_scoped_api_token(1, 'read-api', [
			api_token_scope_read_api,
		], expires_at)!

		assert app.git_http_credential_is_valid(alice, read_token, false)
		assert !app.git_http_credential_is_valid(alice, read_token, true)
		assert app.git_http_credential_is_valid(alice, write_token, false)
		assert app.git_http_credential_is_valid(alice, write_token, true)
		assert !app.git_http_credential_is_valid(alice, read_api_token, false)
		assert !app.git_http_credential_is_valid(alice, read_api_token, true)
	} $else {
		assert true
	}
}
