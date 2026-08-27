module main

import config
import git
import os

fn approval_head_git(args []string) string {
	result := git.Git.exec(args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn approval_head_commit(work_dir string, contents string, message string) !string {
	os.write_file(os.join_path(work_dir, 'feature.txt'), contents)!
	approval_head_git(['-C', work_dir, 'add', 'feature.txt'])
	approval_head_git(['-C', work_dir, 'commit', '-m', message])
	return approval_head_git(['-C', work_dir, 'rev-parse', 'HEAD'])
}

fn approval_head_insert_user(mut app App, id int, username string) ! {
	user := User{
		id:            id
		username:      username
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
}

fn test_approvals_are_bound_to_the_reviewed_head_and_merge_rejects_a_racing_push() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_pr_approval_head_${os.getpid()}')
		os.rmdir_all(root) or {}
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		work_dir := os.join_path(root, 'work')
		bare_dir := os.join_path(root, 'project.git')
		approval_head_git(['init', '-b', 'main', work_dir])
		approval_head_git(['-C', work_dir, 'config', 'user.name', 'Test User'])
		approval_head_git(['-C', work_dir, 'config', 'user.email', 'test@example.com'])
		os.write_file(os.join_path(work_dir, 'README.md'), 'base\n')!
		approval_head_git(['-C', work_dir, 'add', 'README.md'])
		approval_head_git(['-C', work_dir, 'commit', '-m', 'base'])
		base_oid := approval_head_git(['-C', work_dir, 'rev-parse', 'HEAD'])
		approval_head_git(['-C', work_dir, 'checkout', '-b', 'feature'])
		first_head_oid := approval_head_commit(work_dir, 'first\n', 'first feature revision')!
		approval_head_git(['init', '--bare', bare_dir])
		approval_head_git(['-C', work_dir, 'remote', 'add', 'origin', bare_dir])
		approval_head_git(['-C', work_dir, 'push', 'origin', 'main', 'feature'])

		conf := config.Config{
			repo_storage_path: root
			archive_path:      root
			avatars_path:      root
			sqlite:            config.SqliteConfig{
				path: os.join_path(root, 'test.sqlite')
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
		approval_head_insert_user(mut app, 1, 'owner')!
		approval_head_insert_user(mut app, 2, 'reviewer')!
		app.add_repo(Repo{
			id:                 1
			git_dir:            bare_dir
			name:               'project'
			user_id:            1
			user_name:          'owner'
			is_public:          true
			primary_branch:     'main'
			required_approvals: 1
			status:             .done
		})!
		app.add_project_member(1, 2, 'developer')!
		pr_id := app.add_pull_request(1, 1, 'Feature', '', 'feature', 'main')!
		pr := app.find_pull_request_by_id(pr_id) or { panic('merge request missing') }
		repo := app.find_repo_by_id(1) or { panic('repository missing') }

		app.approve_pull_request(pr.id, 2)!
		approvals := sql app.db {
			select from PrApproval where pr_id == pr_id
		}!
		assert approvals.len == 1
		assert approvals[0].approved_head_oid == first_head_oid
		assert app.pull_request_approval_count(pr.id) == 1
		assert app.pull_request_approvals_satisfied_at_head(pr, repo, first_head_oid)

		second_head_oid := approval_head_commit(work_dir, 'second\n', 'second feature revision')!
		approval_head_git(['-C', work_dir, 'push', 'origin', 'feature'])
		// Even if the normal push invalidation callback is delayed or fails, the
		// retained row cannot count for a different full object id.
		assert app.pull_request_approval_count(pr.id) == 0
		assert !app.user_approved_pull_request(pr.id, 2)
		assert !app.pull_request_approvals_satisfied_at_head(pr, repo, second_head_oid)
		app.approve_pull_request(pr.id, 2)!
		updated_approvals := sql app.db {
			select from PrApproval where pr_id == pr_id
		}!
		assert updated_approvals.len == 1
		assert updated_approvals[0].approved_head_oid == second_head_oid

		// Simulate a source push after the route resolved and gated second_head_oid
		// but before it publishes the merge result.
		third_head_oid := approval_head_commit(work_dir, 'third\n', 'racing feature revision')!
		approval_head_git(['-C', work_dir, 'push', 'origin', 'feature'])
		mut merge_rejected := false
		merge_branches_in_bare_at_head(repo, 'main', 'feature', second_head_oid, 'Reviewer',
			'merge') or { merge_rejected = true }
		assert merge_rejected
		mut squash_rejected := false
		squash_branches_in_bare_at_head(repo, 'main', 'feature', second_head_oid, 'Reviewer',
			'squash') or { squash_rejected = true }
		assert squash_rejected
		mut ref_transaction_rejected := false
		update_branch_ref_guarding_head(bare_dir, 'main', second_head_oid, base_oid, 'feature',
			second_head_oid) or { ref_transaction_rejected = true }
		assert ref_transaction_rejected
		assert approval_head_git(['-C', bare_dir, 'rev-parse', 'main']) == base_oid
		assert app.pull_request_approval_count(pr.id) == 0

		app.approve_pull_request(pr.id, 2)!
		assert app.pull_request_approvals_satisfied_at_head(pr, repo, third_head_oid)
		merge_oid := merge_branches_in_bare_at_head(repo, 'main', 'feature', third_head_oid,
			'Reviewer', 'merge')!
		assert merge_oid == third_head_oid
		assert approval_head_git(['-C', bare_dir, 'rev-parse', 'main']) == third_head_oid
	} $else {
		assert true
	}
}
