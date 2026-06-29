module main

import config
import os

fn test_repo_issue_count_excludes_pull_request_rows() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_issue_count_${os.getpid()}.sqlite')
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
		app.add_repo(Repo{
			id:        1
			name:      'repo'
			user_id:   1
			user_name: 'alice'
		})!
		app.add_imported_issue_returning_id(1, 1, 'issue', 'body', 1)!
		pr_issue := Issue{
			repo_id:    1
			author_id:  1
			is_pr:      true
			title:      'pull request'
			text:       'body'
			created_at: 2
		}
		sql app.db {
			insert pr_issue into Issue
		}!

		assert app.get_repo_issue_count(1) == 1
		app.sync_repo_open_issue_count(1)!
		repo := app.find_repo_by_id(1) or { panic('repo missing') }
		assert repo.nr_open_issues == 1
	} $else {
		assert true
	}
}
