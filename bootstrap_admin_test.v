module main

import config
import os

fn bootstrap_admin_test_config(db_path string) config.Config {
	return config.Config{
		repo_storage_path: os.temp_dir()
		archive_path:      os.temp_dir()
		avatars_path:      os.temp_dir()
		sqlite:            config.SqliteConfig{
			path: db_path
		}
	}
}

fn remove_bootstrap_admin_test_db(db_path string) {
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn add_bootstrap_admin_test_user(mut app App, id int, username string, is_admin bool) ! {
	user := User{
		id:            id
		username:      username
		password:      'unused'
		is_registered: true
		is_admin:      is_admin
	}
	sql app.db {
		insert user into User
	}!
}

fn claim_bootstrap_from_separate_connection(db_path string, user_id int, start chan bool) !bool {
	_ := <-start
	conf := bootstrap_admin_test_config(db_path)
	mut app := App{
		db:     connect_db(conf)!
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	return app.claim_bootstrap_administrator(user_id)
}

fn test_bootstrap_claim_is_atomic_and_does_not_limit_later_admins() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_bootstrap_claim_${os.getpid()}.sqlite')
		remove_bootstrap_admin_test_db(db_path)
		defer {
			remove_bootstrap_admin_test_db(db_path)
		}
		conf := bootstrap_admin_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.migrate_tables()!
		add_bootstrap_admin_test_user(mut app, 1, 'alice', false)!
		add_bootstrap_admin_test_user(mut app, 2, 'bob', false)!

		start := chan bool{cap: 2}
		worker_a := spawn claim_bootstrap_from_separate_connection(db_path, 1, start)
		worker_b := spawn claim_bootstrap_from_separate_connection(db_path, 2, start)
		start <- true
		start <- true
		claimed_a := worker_a.wait()!
		claimed_b := worker_b.wait()!
		assert claimed_a != claimed_b
		rows := db_exec_values(mut app.db,
			'select id from ${sql_table('User')} where ${sql_table('is_bootstrap_admin')} is true')!
		assert rows.len == 1
		bootstrap_id := rows[0][0].int()
		other_id := if bootstrap_id == 1 { 2 } else { 1 }
		bootstrap_user := app.get_user_by_id(bootstrap_id) or { panic('bootstrap user missing') }
		assert bootstrap_user.is_admin
		assert bootstrap_user.is_bootstrap_admin
		// Even a caller that bypasses the helper cannot create a second claim;
		// the database index, not process-local state, enforces the invariant.
		// sqlite.DB.exec does not surface sqlite3_step constraint errors in the
		// V version supported by Gitly, so assert the durable database state.
		app.db.exec('update ${sql_table('User')} set ${sql_table('is_bootstrap_admin')} = true where ${sql_table('id')} = ${other_id}') or {}
		after_forced_duplicate := db_exec_values(mut app.db,
			'select id from ${sql_table('User')} where ${sql_table('is_bootstrap_admin')} is true')!
		assert after_forced_duplicate == [[bootstrap_id.str()]]

		// The uniqueness rule covers only the bootstrap marker. Administrators
		// created later remain supported.
		app.add_admin(other_id)!
		later_admin := app.get_user_by_id(other_id) or { panic('second user missing') }
		assert later_admin.is_admin
		assert !later_admin.is_bootstrap_admin
		assert app.count_admin_users() == 2
	} $else {
		assert true
	}
}

fn test_bootstrap_migration_backfills_an_existing_installation() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_bootstrap_migration_${os.getpid()}.sqlite')
		remove_bootstrap_admin_test_db(db_path)
		defer {
			remove_bootstrap_admin_test_db(db_path)
		}
		conf := bootstrap_admin_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		// Simulate a pre-migration schema and an installation whose historical
		// first-user race left no administrator.
		app.db.exec('drop table ${sql_table('User')}')!
		app.db.exec('create table ${sql_table('User')} (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			full_name TEXT NOT NULL DEFAULT \'\',
			username TEXT NOT NULL UNIQUE,
			github_username TEXT NOT NULL DEFAULT \'\',
			password TEXT NOT NULL DEFAULT \'\',
			salt TEXT NOT NULL DEFAULT \'\',
			created_at INTEGER NOT NULL DEFAULT 0,
			is_github INTEGER NOT NULL DEFAULT 0,
			is_registered INTEGER NOT NULL DEFAULT 0,
			is_blocked INTEGER NOT NULL DEFAULT 0,
			is_admin INTEGER NOT NULL DEFAULT 0,
			namechanges_count INTEGER NOT NULL DEFAULT 0,
			last_namechange_time INTEGER NOT NULL DEFAULT 0,
			posts_count INTEGER NOT NULL DEFAULT 0,
			last_post_time INTEGER NOT NULL DEFAULT 0,
			avatar TEXT NOT NULL DEFAULT \'\',
			login_attempts INTEGER NOT NULL DEFAULT 0,
			login_attempt_window_started_at BIGINT NOT NULL DEFAULT 0,
			login_throttled_until BIGINT NOT NULL DEFAULT 0
		)')!
		app.db.exec("insert into ${sql_table('User')} (id, username, password, is_registered, is_admin) values (1, 'legacy', 'unused', true, false)")!

		app.migrate_tables()!

		assert db_column_exists(mut app.db, 'User', 'is_bootstrap_admin')!
		legacy := app.get_user_by_id(1) or { panic('legacy user missing') }
		assert legacy.is_admin
		assert legacy.is_bootstrap_admin
		assert !app.claim_bootstrap_administrator(1)!
	} $else {
		assert true
	}
}

fn test_failed_registration_does_not_claim_bootstrap() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_bootstrap_failure_${os.getpid()}.sqlite')
		remove_bootstrap_admin_test_db(db_path)
		defer {
			remove_bootstrap_admin_test_db(db_path)
		}
		conf := bootstrap_admin_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.migrate_tables()!

		if _ := app.register_user('broken', 'unused', '', ['not-an-email'], false, false) {
			assert false
		}
		rows := db_exec_values(mut app.db,
			'select count(*) from ${sql_table('User')} where ${sql_table('is_bootstrap_admin')} is true')!
		assert rows == [['0']]

		add_bootstrap_admin_test_user(mut app, 1, 'alice', false)!
		assert app.claim_bootstrap_administrator(1)!
	} $else {
		assert true
	}
}
