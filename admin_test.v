module main

import config
import os
import time

struct AdminEditResult {
	succeeded bool
}

fn admin_test_config(db_path string) config.Config {
	return config.Config{
		repo_storage_path: os.temp_dir()
		archive_path:      os.temp_dir()
		avatars_path:      os.temp_dir()
		sqlite:            config.SqliteConfig{
			path: db_path
		}
	}
}

fn remove_admin_test_db(db_path string) {
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn add_admin_test_user(mut app App, id int, username string) ! {
	user := User{
		id:            id
		username:      username
		created_at:    time.now()
		is_registered: true
		is_admin:      true
	}
	app.add_user(user)!
}

fn concurrently_deactivate_admin(db_path string, user_id int, start chan bool) AdminEditResult {
	_ := <-start
	conf := admin_test_config(db_path)
	mut app := App{
		db:     connect_db(conf) or { return AdminEditResult{} }
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	app.edit_user(user_id, false, false, false) or { return AdminEditResult{} }
	return AdminEditResult{
		succeeded: true
	}
}

fn test_admin_edits_cannot_concurrently_remove_every_active_admin() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_admin_edit_${os.getpid()}.sqlite')
		remove_admin_test_db(db_path)
		defer {
			remove_admin_test_db(db_path)
		}
		conf := admin_test_config(db_path)
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		add_admin_test_user(mut app, 1, 'alice')!
		add_admin_test_user(mut app, 2, 'bob')!

		start := chan bool{cap: 2}
		worker_a := spawn concurrently_deactivate_admin(db_path, 1, start)
		worker_b := spawn concurrently_deactivate_admin(db_path, 2, start)
		start <- true
		start <- true
		result_a := worker_a.wait()
		result_b := worker_b.wait()
		assert result_a.succeeded || result_b.succeeded
		assert !(result_a.succeeded && result_b.succeeded)
		assert app.count_admin_users() == 1

		remaining := sql app.db {
			select from User where is_admin == true && is_registered == true && is_blocked == false
		}!
		assert remaining.len == 1
		mut rejected := false
		app.edit_user(remaining[0].id, false, true, true) or { rejected = true }
		assert rejected
		assert app.count_admin_users() == 1
	} $else {
		assert true
	}
}
