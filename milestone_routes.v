// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

@['/:username/:repo_name/milestones']
pub fn (mut app App) handle_get_repo_milestones(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	milestones := app.list_repo_milestones(repo.id)
	return $veb.html('templates/milestones.html')
}

@['/:username/:repo_name/milestones/new']
pub fn (mut app App) new_milestone(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/milestones')
	}
	return $veb.html('templates/new/milestone.html')
}

@['/:username/:repo_name/milestones'; post]
pub fn (mut app App) handle_create_milestone(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/milestones')
	}
	title := ctx.form['title']
	desc := ctx.form['description']
	due := parse_yyyy_mm_dd(ctx.form['due_date'])
	if !valid_title(title) || !valid_body(desc) {
		return ctx.redirect('/${username}/${repo_name}/milestones/new')
	}
	id := app.add_milestone(repo.id, title, desc, due) or {
		ctx.error('Could not create milestone')
		return ctx.redirect('/${username}/${repo_name}/milestones/new')
	}
	return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
}

@['/:username/:repo_name/milestones/:id']
pub fn (mut app App) view_milestone(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	milestone := app.find_milestone(id.int()) or { return ctx.not_found() }
	if milestone.repo_id != repo.id {
		return ctx.not_found()
	}
	can_edit := app.can_admin_repo(ctx, repo)
	return $veb.html('templates/milestone.html')
}

@['/:username/:repo_name/milestones/:id/close'; post]
pub fn (mut app App) handle_close_milestone(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	milestone := app.find_milestone(id.int()) or { return ctx.not_found() }
	if milestone.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
	}
	app.set_milestone_closed(milestone.id, true) or {}
	return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
}

@['/:username/:repo_name/milestones/:id/reopen'; post]
pub fn (mut app App) handle_reopen_milestone(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	milestone := app.find_milestone(id.int()) or { return ctx.not_found() }
	if milestone.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
	}
	app.set_milestone_closed(milestone.id, false) or {}
	return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
}

@['/:username/:repo_name/milestones/:id/delete'; post]
pub fn (mut app App) handle_delete_milestone(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.milestones_enabled() {
		return ctx.not_found()
	}
	milestone := app.find_milestone(id.int()) or { return ctx.not_found() }
	if milestone.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/milestones/${id}')
	}
	app.delete_milestone(milestone.id) or {}
	return ctx.redirect('/${username}/${repo_name}/milestones')
}
