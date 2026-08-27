module main

import config
import os

fn login_throttle_test_config(db_path string) config.Config {
	return config.Config{
		repo_storage_path: os.temp_dir()
		archive_path:      os.temp_dir()
		avatars_path:      os.temp_dir()
		sqlite:            config.SqliteConfig{
			path: db_path
		}
	}
}

fn remove_login_throttle_test_db(db_path string) {
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn insert_login_throttle_test_user(mut app App) ! {
	user := User{
		id:            1
		username:      'alice'
		password:      'unused'
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
}

fn test_failed_logins_use_a_persisted_expiring_throttle() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_login_throttle_${os.getpid()}.sqlite')
		remove_login_throttle_test_db(db_path)
		defer {
			remove_login_throttle_test_db(db_path)
		}
		conf := login_throttle_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		insert_login_throttle_test_user(mut app)!

		now := i64(2_000_000)
		for attempt := 1; attempt <= max_login_attempts; attempt++ {
			app.record_failed_login(1, now + i64(attempt) - 1)!
			current := app.get_user_by_id(1) or { panic('test user missing') }
			assert current.login_attempts == attempt
			assert current.login_attempt_window_started_at == now
			if attempt < max_login_attempts {
				assert current.login_throttled_until == 0
			}
		}

		locked := app.get_user_by_id(1) or { panic('test user missing') }
		expected_until := now + i64(max_login_attempts) - 1 + login_throttle_seconds
		assert locked.login_throttled_until == expected_until
		assert user_login_is_throttled(locked, expected_until - 1)
		assert !locked.is_blocked

		// A second connection observes the throttle, just as a restarted process
		// would, and failures during it cannot keep extending the deadline.
		mut restarted := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			restarted.db.close() or {}
		}
		persisted := restarted.get_user_by_id(1) or { panic('persisted user missing') }
		assert persisted.login_throttled_until == expected_until
		restarted.record_failed_login(1, expected_until - 1)!
		still_locked := restarted.get_user_by_id(1) or { panic('test user missing') }
		assert still_locked.login_attempts == max_login_attempts
		assert still_locked.login_throttled_until == expected_until

		// At expiry a new failure starts a clean window instead of reusing or
		// permanently extending the old lock.
		restarted.record_failed_login(1, expected_until)!
		fresh := restarted.get_user_by_id(1) or { panic('test user missing') }
		assert fresh.login_attempts == 1
		assert fresh.login_attempt_window_started_at == expected_until
		assert fresh.login_throttled_until == 0

		restarted.reset_user_login_throttle(1)!
		reset := restarted.get_user_by_id(1) or { panic('test user missing') }
		assert reset.login_attempts == 0
		assert reset.login_attempt_window_started_at == 0
		assert reset.login_throttled_until == 0
	} $else {
		assert true
	}
}

fn test_login_throttle_columns_are_migrated_for_existing_users() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(),
			'gitly_login_throttle_migration_${os.getpid()}.sqlite')
		remove_login_throttle_test_db(db_path)
		defer {
			remove_login_throttle_test_db(db_path)
		}
		conf := login_throttle_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
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
			avatar TEXT NOT NULL DEFAULT \'\'
		)')!
		app.db.exec("insert into ${sql_table('User')} (id, username, is_registered, is_blocked) values (1, 'legacy', 1, 0)")!

		app.migrate_tables()!

		assert db_column_exists(mut app.db, 'User', 'login_attempts')!
		assert db_column_exists(mut app.db, 'User', 'login_attempt_window_started_at')!
		assert db_column_exists(mut app.db, 'User', 'login_throttled_until')!
		rows := db_exec_values(mut app.db,
			'select login_attempts, login_attempt_window_started_at, login_throttled_until from ${sql_table('User')}')!
		assert rows == [['0', '0', '0']]
	} $else {
		assert true
	}
}
