module main

import config
import os

fn pr_authorization_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_pr_authorization_${os.getpid()}.sqlite')
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

fn insert_pr_authorization_test_user(mut app App, id int, username string) ! {
	user := User{
		id:            id
		username:      username
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
}

fn test_revoked_private_project_author_cannot_close_or_reopen_pr() {
	$if sqlite ? {
		mut app, db_path := pr_authorization_test_app()!
		defer {
			app.db.close() or {}
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}

		insert_pr_authorization_test_user(mut app, 1, 'owner')!
		insert_pr_authorization_test_user(mut app, 2, 'author')!
		app.add_repo(Repo{
			id:             1
			name:           'private-project'
			user_id:        1
			user_name:      'owner'
			primary_branch: 'main'
		})!
		app.add_project_member(1, 2, 'reporter')!
		pr := PullRequest{
			id:          1
			repo_id:     1
			author_id:   2
			title:       'Author PR'
			head_branch: 'feature'
			base_branch: 'main'
			status:      int(PrStatus.open)
		}
		sql app.db {
			insert pr into PullRequest
		}!
		repo := app.find_repo_by_id(1) or { panic('repo missing') }
		author_ctx := Context{
			logged_in: true
			user:      User{
				id:       2
				username: 'author'
			}
		}
		assert app.can_read_repo(author_ctx, repo)

		member := app.find_project_members(repo.id).first().member
		app.remove_project_member(repo.id, member.id)!
		assert !app.can_read_repo(author_ctx, repo)

		mut close_ctx := author_ctx
		app.handle_close_pr(mut close_ctx, 'owner', repo.name, pr.id.str())
		after_close := app.find_pull_request_by_id(pr.id) or { panic('PR missing') }
		assert after_close.is_open()

		app.set_pr_status(pr.id, .closed)!
		mut reopen_ctx := author_ctx
		app.handle_reopen_pr(mut reopen_ctx, 'owner', repo.name, pr.id.str())
		after_reopen := app.find_pull_request_by_id(pr.id) or { panic('PR missing') }
		assert after_reopen.is_closed()
	} $else {
		assert true
	}
}
