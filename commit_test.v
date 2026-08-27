module main

import config
import os

fn test_commit_queries_are_deterministic_when_timestamps_match() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_commit_${os.getpid()}.sqlite')
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
		older_id := 1
		newer_id := 2
		created_at := 1_700_000_000
		first := Commit{
			id:         older_id
			hash:       'aaaaaaa'
			created_at: created_at
			repo_id:    1
			message:    'first'
		}
		second := Commit{
			id:         newer_id
			hash:       'bbbbbbb'
			created_at: created_at
			repo_id:    1
			message:    'second'
		}
		sql app.db {
			insert first into Commit
		}!
		sql app.db {
			insert second into Commit
		}!
		first_link := BranchCommit{
			branch_id: 1
			commit_id: older_id
		}
		second_link := BranchCommit{
			branch_id: 1
			commit_id: newer_id
		}
		sql app.db {
			insert first_link into BranchCommit
		}!
		sql app.db {
			insert second_link into BranchCommit
		}!

		commits := app.find_repo_commits_as_page(1, 1, 0)
		assert commits.len == 2
		assert commits[0].id == newer_id
		assert app.find_repo_last_commit(1, 1).id == newer_id
	} $else {
		assert true
	}
}

fn test_user_daily_activity_rejects_invalid_ranges() {
	app := App{}
	assert app.get_user_daily_activity(0, 10).len == 0
	assert app.get_user_daily_activity(1, 0).len == 0
	assert app.get_user_daily_activity(1, -1).len == 0
}
