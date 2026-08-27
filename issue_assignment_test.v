module main

import config
import os

fn issue_assignment_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_issue_assignment_${os.getpid()}.sqlite')
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

fn cleanup_issue_assignment_test(mut app App, db_path string) {
	app.db.close() or {}
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn insert_issue_assignment_test_user(mut app App, id int, username string, blocked bool) ! {
	user := User{
		id:            id
		username:      username
		is_registered: true
		is_blocked:    blocked
	}
	sql app.db {
		insert user into User
	}!
}

fn test_issue_assignment_is_idempotent_and_membership_scoped() {
	$if sqlite ? {
		mut app, db_path := issue_assignment_test_app()!
		defer {
			cleanup_issue_assignment_test(mut app, db_path)
		}
		insert_issue_assignment_test_user(mut app, 1, 'owner', false)!
		insert_issue_assignment_test_user(mut app, 2, 'reporter', false)!
		insert_issue_assignment_test_user(mut app, 3, 'developer', false)!
		insert_issue_assignment_test_user(mut app, 4, 'outsider', false)!
		insert_issue_assignment_test_user(mut app, 5, 'blocked-member', true)!
		app.add_repo(Repo{
			id:             1
			name:           'public-project'
			user_id:        1
			user_name:      'owner'
			is_public:      true
			primary_branch: 'main'
		})!
		app.add_project_member(1, 2, 'reporter')!
		app.add_project_member(1, 3, 'developer')!
		app.add_project_member(1, 5, 'developer')!
		issue_id := app.add_imported_issue_returning_id(1, 1, 'Assignable', 'Body', 10)!

		app.assign_issue(issue_id, 1)!
		app.assign_issue(issue_id, 1)!
		app.assign_issue(issue_id, 2)!
		assignment_count := sql app.db {
			select count from IssueAssignee where issue_id == issue_id
		}!
		assert assignment_count == 2

		mut outsider_rejected := false
		app.assign_issue(issue_id, 4) or { outsider_rejected = true }
		assert outsider_rejected
		mut blocked_rejected := false
		app.assign_issue(issue_id, 5) or { blocked_rejected = true }
		assert blocked_rejected

		issue := app.find_issue_by_id(issue_id) or { panic('issue missing') }
		assert issue.assigned == [1, 2]
		assert app.find_user_assigned_issues(2).map(it.id) == [issue_id]
		assert app.find_issue_assignable_users(Repo{
			id:        1
			user_id:   1
			user_name: 'owner'
			is_public: true
		}).map(it.id) == [3, 1, 2]
	} $else {
		assert true
	}
}

fn test_issue_unassignment_is_idempotent_and_stale_memberships_are_hidden() {
	$if sqlite ? {
		mut app, db_path := issue_assignment_test_app()!
		defer {
			cleanup_issue_assignment_test(mut app, db_path)
		}
		insert_issue_assignment_test_user(mut app, 1, 'owner', false)!
		insert_issue_assignment_test_user(mut app, 2, 'member', false)!
		app.add_repo(Repo{
			id:             1
			name:           'project'
			user_id:        1
			user_name:      'owner'
			is_public:      true
			primary_branch: 'main'
		})!
		app.add_project_member(1, 2, 'developer')!
		issue_id := app.add_imported_issue_returning_id(1, 1, 'Issue', 'Body', 10)!
		app.assign_issue(issue_id, 2)!

		member := app.find_project_members(1).first().member
		app.remove_project_member(1, member.id)!
		assert app.find_user_assigned_issues(2).len == 0
		stale_issue := app.find_issue_by_id(issue_id) or { panic('issue missing') }
		assert stale_issue.assigned.len == 0

		app.unassign_issue(issue_id, 2)!
		app.unassign_issue(issue_id, 2)!
		assert app.get_issue_assignee_ids(issue_id).len == 0

		app.assign_issue(issue_id, 1)!
		app.delete_repo_issues(1)!
		remaining_assignments := sql app.db {
			select count from IssueAssignee
		}!
		assert remaining_assignments == 0
	} $else {
		assert true
	}
}
