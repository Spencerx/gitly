module main

import config
import os

fn test_migrate_tables_adds_pull_request_merge_columns() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_pr_migration_${os.getpid()}.sqlite')
		os.rm(db_path) or {}
		defer {
			os.rm(db_path) or {}
			os.rm(db_path + '-shm') or {}
			os.rm(db_path + '-wal') or {}
		}
		conf := config.Config{
			repo_storage_path: os.temp_dir()
			archive_path:      os.temp_dir()
			avatars_path:      os.temp_dir()
			sqlite:            config.SqliteConfig{
				path: db_path
			}
		}
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.db.exec('drop table ${sql_table('PullRequest')}')!
		app.db.exec('create table ${sql_table('PullRequest')} (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			repo_id INTEGER NOT NULL DEFAULT 0,
			author_id INTEGER NOT NULL DEFAULT 0,
			title TEXT,
			description TEXT,
			head_branch TEXT,
			base_branch TEXT,
			status INTEGER NOT NULL DEFAULT 0,
			comments_count INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL DEFAULT 0
		)')!

		app.migrate_tables()!

		assert db_column_exists(mut app.db, 'PullRequest', 'merged_at')!
		assert db_column_exists(mut app.db, 'PullRequest', 'merge_commit_hash')!

		pr_id := app.add_pull_request(1, 2, 'title', 'description', 'feature', 'main')!
		app.set_pr_merged(pr_id, 'abc123')!
		pr := app.find_pull_request_by_id(pr_id) or { panic('pull request missing') }
		assert pr.status == int(PrStatus.merged)
		assert pr.merged_at > 0
		assert pr.merge_commit_hash == 'abc123'
	} $else {
		assert true
	}
}
