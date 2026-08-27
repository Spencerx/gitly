module main

import config
import crypto.sha256
import os
import time

fn api_token_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_api_token_${os.getpid()}.sqlite')
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

fn cleanup_api_token_test_app(mut app App, db_path string) {
	app.db.close() or {}
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn insert_api_token_test_user(mut app App, id int, username string) ! {
	user := User{
		id:            id
		username:      username
		password:      sha256.sum('unused'.bytes()).hex()
		salt:          'salt'
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
}

fn scoped_api_token_creation_fails(mut app App, scopes []string, expires_at int) bool {
	app.add_scoped_api_token(1, 'rejected', scopes, expires_at) or { return true }
	return false
}

fn test_api_token_migration_preserves_legacy_access() {
	$if sqlite ? {
		mut app, db_path := api_token_test_app()!
		defer {
			cleanup_api_token_test_app(mut app, db_path)
		}
		insert_api_token_test_user(mut app, 1, 'legacy')!
		app.db.exec('drop table ${sql_table('ApiToken')}')!
		app.db.exec('create table ${sql_table('ApiToken')} (
			id integer primary key autoincrement,
			user_id integer not null,
			name text not null,
			token_hash text not null,
			created_at integer not null,
			last_used_at integer not null
		)')!
		plain := 'glt_legacy_test_token'
		app.db.exec("insert into ${sql_table('ApiToken')}
			(user_id, name, token_hash, created_at, last_used_at)
			values (1, 'legacy', '${hash_api_token(plain)}', 1, 0)")!

		app.migrate_tables()!
		assert db_column_exists(mut app.db, 'ApiToken', 'scopes')!
		assert db_column_exists(mut app.db, 'ApiToken', 'expires_at')!
		tokens := app.list_user_api_tokens(1)
		assert tokens.len == 1
		assert tokens[0].scopes == api_token_scope_api
		assert tokens[0].expires_at == 0
		assert (app.user_for_api_token(plain, api_token_scope_read_api) or { User{} }).id == 1
		assert app.api_token_authenticates_user(plain, 1, api_token_scope_write_repository)
	} $else {
		assert true
	}
}

fn test_api_token_scopes_and_expiry_are_enforced() {
	$if sqlite ? {
		mut app, db_path := api_token_test_app()!
		defer {
			cleanup_api_token_test_app(mut app, db_path)
		}
		insert_api_token_test_user(mut app, 1, 'scoped')!
		now := int(time.now().unix())

		_, read_api_token := app.add_scoped_api_token(1, 'read api', [
			api_token_scope_read_api,
		], now + 3600)!
		assert (app.user_for_api_token(read_api_token, api_token_scope_read_api) or { User{} }).id == 1
		assert (app.user_for_api_token(read_api_token, api_token_scope_api) or { User{} }).id == 0
		assert !app.api_token_authenticates_user(read_api_token, 1, api_token_scope_read_repository)

		_, read_repo_token := app.add_scoped_api_token(1, 'read repo', [
			api_token_scope_read_repository,
		], now + 3600)!
		assert app.api_token_authenticates_user(read_repo_token, 1, api_token_scope_read_repository)
		assert !app.api_token_authenticates_user(read_repo_token, 1,
			api_token_scope_write_repository)

		_, write_repo_token := app.add_scoped_api_token(1, 'write repo', [
			api_token_scope_write_repository,
		], now + 3600)!
		assert app.api_token_authenticates_user(write_repo_token, 1,
			api_token_scope_read_repository)
		assert app.api_token_authenticates_user(write_repo_token, 1,
			api_token_scope_write_repository)

		expired_id, expired_token := app.add_scoped_api_token(1, 'expired', [
			api_token_scope_api,
		], now + 3600)!
		expired_at := now - 1
		sql app.db {
			update ApiToken set expires_at = expired_at where id == expired_id
		}!
		assert (app.user_for_api_token(expired_token, api_token_scope_read_api) or { User{} }).id == 0
		expired_rows := app.list_user_api_tokens(1).filter(it.id == expired_id)
		assert expired_rows.len == 1
		assert expired_rows[0].last_used_at == 0

		assert scoped_api_token_creation_fails(mut app, [], now + 3600)
		assert scoped_api_token_creation_fails(mut app, ['unknown'], now + 3600)
		assert scoped_api_token_creation_fails(mut app, [api_token_scope_read_api], 0)
		assert scoped_api_token_creation_fails(mut app, [api_token_scope_read_api], now +
			(api_token_max_expiry_days + 1) * 24 * 60 * 60)
	} $else {
		assert true
	}
}
