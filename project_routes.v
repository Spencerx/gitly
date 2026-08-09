// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

struct ProjectColumnView {
	column ProjectColumn
	cards  []ProjectCard
}

@['/:username/:repo_name/projects']
pub fn (mut app App) handle_get_repo_projects(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	projects := app.list_repo_projects(repo.id)
	return $veb.html('templates/projects.html')
}

@['/:username/:repo_name/projects/new']
pub fn (mut app App) new_project(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects')
	}
	return $veb.html('templates/new/project.html')
}

@['/:username/:repo_name/projects'; post]
pub fn (mut app App) handle_create_project(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects')
	}
	name := ctx.form['name']
	desc := ctx.form['description']
	if !valid_short_name(name) || !valid_body(desc) {
		return ctx.redirect('/${username}/${repo_name}/projects/new')
	}
	id := app.add_project(repo.id, name, desc) or {
		ctx.error('Could not create project')
		return ctx.redirect('/${username}/${repo_name}/projects/new')
	}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id']
pub fn (mut app App) view_project(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id {
		return ctx.not_found()
	}
	columns := app.list_project_columns(project.id)
	mut views := []ProjectColumnView{}
	for col in columns {
		views << ProjectColumnView{
			column: col
			cards:  app.list_project_cards(col.id)
		}
	}
	can_edit := app.can_admin_repo(ctx, repo)
	return $veb.html('templates/project.html')
}

@['/:username/:repo_name/projects/:id/columns'; post]
pub fn (mut app App) handle_add_project_column(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	name := ctx.form['name']
	if !valid_short_name(name) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	pos := app.list_project_columns(project.id).len
	app.add_project_column(project.id, name, pos) or {}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id/columns/:col_id/delete'; post]
pub fn (mut app App) handle_delete_project_column(mut ctx Context, username string, repo_name string, id string, col_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	col := app.find_project_column(col_id.int()) or { return ctx.not_found() }
	if col.project_id != project.id {
		return ctx.not_found()
	}
	app.delete_project_column(col.id) or {}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id/columns/:col_id/cards'; post]
pub fn (mut app App) handle_add_project_card(mut ctx Context, username string, repo_name string, id string, col_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	col := app.find_project_column(col_id.int()) or { return ctx.not_found() }
	if col.project_id != project.id {
		return ctx.not_found()
	}
	title := ctx.form['title']
	note := ctx.form['note']
	if !valid_title(title) || !valid_body(note) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	app.add_project_card(col.id, title, note) or {}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id/cards/:card_id/delete'; post]
pub fn (mut app App) handle_delete_project_card(mut ctx Context, username string, repo_name string, id string, card_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	card := app.find_project_card(card_id.int()) or { return ctx.not_found() }
	card_col := app.find_project_column(card.column_id) or { return ctx.not_found() }
	if card_col.project_id != project.id {
		return ctx.not_found()
	}
	app.delete_project_card(card.id) or {}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id/cards/:card_id/move'; post]
pub fn (mut app App) handle_move_project_card(mut ctx Context, username string, repo_name string, id string, card_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	new_col := ctx.form['column_id'].int()
	card := app.find_project_card(card_id.int()) or { return ctx.not_found() }
	old_col := app.find_project_column(card.column_id) or { return ctx.not_found() }
	destination := app.find_project_column(new_col) or { return ctx.not_found() }
	if old_col.project_id != project.id || destination.project_id != project.id {
		return ctx.not_found()
	}
	app.move_project_card(card.id, destination.id) or {}
	return ctx.redirect('/${username}/${repo_name}/projects/${id}')
}

@['/:username/:repo_name/projects/:id/delete'; post]
pub fn (mut app App) handle_delete_project(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !repo.projects_enabled() {
		return ctx.not_found()
	}
	project := app.find_project(id.int()) or { return ctx.not_found() }
	if project.repo_id != repo.id || !app.can_admin_repo(ctx, repo) {
		return ctx.redirect('/${username}/${repo_name}/projects/${id}')
	}
	app.delete_project(project.id) or {}
	return ctx.redirect('/${username}/${repo_name}/projects')
}
