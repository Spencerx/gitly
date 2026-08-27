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
		assert db_column_exists(mut app.db, 'Issue', 'status')!
		app.add_repo(Repo{
			id:        1
			name:      'repo'
			user_id:   1
			user_name: 'alice'
		})!
		issue_id := app.add_imported_issue_returning_id(1, 1, 'issue', 'body', 1)!
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
		assert app.get_repo_all_issue_count(1) == 1
		app.set_issue_status(issue_id, .closed)!
		closed := app.find_issue_by_id(issue_id) or { panic('issue missing') }
		assert !closed.is_open()
		assert app.get_repo_issue_count(1) == 0
		assert app.get_repo_all_issue_count(1) == 1
		assert app.get_repo_closed_issue_count(1) == 1
		assert app.find_repo_issues_as_page(1, 0).len == 0
		assert app.find_repo_issues_as_page_by_state(1, 0, 'closed').map(it.id) == [
			issue_id,
		]
		assert app.find_repo_issues_as_page_by_state(1, 0, 'all').map(it.id) == [
			issue_id,
		]
		assert normalize_issue_state('invalid') == 'open'
		app.sync_repo_open_issue_count(1)!
		repo := app.find_repo_by_id(1) or { panic('repo missing') }
		assert repo.nr_open_issues == 0
	} $else {
		assert true
	}
}
