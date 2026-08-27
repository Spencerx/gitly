// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation

@['/:username/:repo_name/fork']
pub fn (mut app App) new_fork(mut ctx Context, username string, repo_name string) veb.Result {
	source := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	if !app.user_has_repo_read_access(ctx.user.id, source) {
		return ctx.not_found()
	}
	orgs := app.find_orgs_administered_by_user(ctx.user.id)
	selected_owner := ctx.form['owner'] or { ctx.user.username }
	return $veb.html('templates/repo/fork.html')
}

@['/:username/:repo_name/fork'; post]
pub fn (mut app App) handle_create_fork(mut ctx Context, username string, repo_name string) veb.Result {
	source := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	if !app.user_has_repo_read_access(ctx.user.id, source) {
		return ctx.not_found()
	}
	owner := ctx.form['owner'] or { ctx.user.username }
	mut owner_name := ctx.user.username
	mut owner_user_id := ctx.user.id
	if owner != ctx.user.username {
		org := app.get_org_by_name(owner) or {
			ctx.error('Unknown destination namespace')
			return app.new_fork(mut ctx, username, repo_name)
		}
		if (app.org_member_role(org.id, ctx.user.id) or { '' }) != 'admin' {
			return ctx.not_found()
		}
		owner_name = org.name
		owner_user_id = ctx.user.id
	}
	name := ctx.form['name'].trim_space()
	description := ctx.form['description'].trim_space()
	if !validation.is_repository_name_valid(name) || name.len > max_repo_name_len
		|| description.len > max_repo_description_len {
		ctx.error('The fork name or description is invalid')
		return app.new_fork(mut ctx, username, repo_name)
	}
	if _ := app.find_repo_by_name_and_username(name, owner_name) {
		ctx.error('A repository with that name already exists in the destination namespace')
		return app.new_fork(mut ctx, username, repo_name)
	}
	if owner_name == ctx.user.username && !ctx.is_admin()
		&& app.get_count_user_repos(ctx.user.id) >= max_user_repos {
		ctx.error('You have reached the limit for the number of repositories')
		return app.new_fork(mut ctx, username, repo_name)
	}
	is_public := ctx.form['repo_visibility'] == 'public' && source.is_public
	created := app.create_fork(source, owner_name, owner_user_id, name, description, is_public,
		ctx.form['default_branch_only'] == 'on', ctx.user.id) or {
		ctx.error(err.str())
		return app.new_fork(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${created.user_name}/${created.name}')
}

@['/:username/:repo_name/forks']
pub fn (mut app App) repo_forks(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	forks := app.find_repo_forks(repo.id).filter(it.is_public
		|| (ctx.logged_in && app.user_has_repo_read_access(ctx.user.id, it)))
	return $veb.html('templates/repo/forks.html')
}

@['/:username/:repo_name/fork/sync'; post]
pub fn (mut app App) handle_sync_fork(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	relation := app.find_fork_by_repo(repo.id) or { return ctx.not_found() }
	source := app.find_repo_by_id(relation.source_repo_id) or { return ctx.not_found() }
	if !app.user_has_repo_read_access(ctx.user.id, source) {
		return ctx.not_found()
	}
	result := app.sync_fork(repo, relation, ctx.form['default_branch_only'] == 'on') or {
		ctx.error(err.str())
		return app.tree(mut ctx, username, repo_name, repo.primary_branch)
	}
	app.info('Fork sync updated ${result.updated.len} branch(es) and left ${result.skipped.len} diverged branch(es) unchanged')
	return ctx.redirect('/${username}/${repo_name}')
}
