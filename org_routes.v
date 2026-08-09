// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation

fn (mut app App) organization(mut ctx Context, org_name string) veb.Result {
	org := app.get_org_by_name(org_name) or { return ctx.not_found() }
	is_member := ctx.logged_in && app.is_org_member(org.id, ctx.user.id)
	can_admin := ctx.logged_in && (app.org_member_role(org.id, ctx.user.id) or { '' }) == 'admin'
	mut repos := app.find_org_repos(org.name, is_member)
	for mut repo in repos {
		repo.lang_stats = app.find_repo_lang_stats(repo.id)
		repo.latest_commit_at = app.find_repo_last_commit_time(repo.id)
	}
	members := app.find_org_members(org.id)
	return $veb.html('templates/org.html')
}

@['/organizations/new']
pub fn (mut app App) new_org(mut ctx Context) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	return $veb.html('templates/new/org.html')
}

@['/organizations/new'; post]
pub fn (mut app App) handle_new_org(mut ctx Context) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	org_name := ctx.form['org_name'].trim_space().to_lower()
	contact_email := ctx.form['contact_email'].trim_space().to_lower()
	org_kind := ctx.form['org_kind']
	accept_terms := ctx.form['accept_terms'] == '1'

	if validation.is_string_empty(org_name) {
		ctx.error('Organization name is required')
		return app.new_org(mut ctx)
	}
	if org_name.len > max_username_len {
		ctx.error('The organization name is too long (should be fewer than ${max_username_len} characters)')
		return app.new_org(mut ctx)
	}
	if org_name.contains(' ') {
		ctx.error('Organization name cannot contain spaces')
		return app.new_org(mut ctx)
	}
	if !validation.is_username_valid(org_name) || is_reserved_account_name(org_name) {
		ctx.error('The organization name is not valid or is reserved')
		return app.new_org(mut ctx)
	}
	if validation.is_string_empty(contact_email) {
		ctx.error('Contact email is required')
		return app.new_org(mut ctx)
	}
	if !validation.is_email_valid(contact_email) {
		ctx.error('Contact email is not valid')
		return app.new_org(mut ctx)
	}
	if org_kind != 'personal' && org_kind != 'business' {
		ctx.error('Please select who this organization belongs to')
		return app.new_org(mut ctx)
	}
	if !accept_terms {
		ctx.error('You must accept the Terms of Service')
		return app.new_org(mut ctx)
	}
	if _ := app.get_user_by_username(org_name) {
		ctx.error('The name "${org_name}" is already taken')
		return app.new_org(mut ctx)
	}
	if _ := app.get_org_by_name(org_name) {
		ctx.error('The name "${org_name}" is already taken')
		return app.new_org(mut ctx)
	}

	org_id := app.add_org(org_name, contact_email, org_kind, ctx.user.id) or {
		ctx.error('Could not create organization: ${err}')
		return app.new_org(mut ctx)
	}
	app.add_org_member(org_id, ctx.user.id, 'admin') or {
		app.delete_org(org_id) or { app.info('failed to roll back organization ${org_id}: ${err}') }
		ctx.error('Could not add you as the organization owner: ${err}')
		return app.new_org(mut ctx)
	}
	return ctx.redirect('/new?owner=${org_name}')
}

@['/organizations/:org_name/members'; post]
pub fn (mut app App) handle_add_org_member(mut ctx Context, org_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	org := app.get_org_by_name(org_name) or { return ctx.not_found() }
	if (app.org_member_role(org.id, ctx.user.id) or { '' }) != 'admin' {
		return ctx.not_found()
	}
	member_name := ctx.form['username'].trim_space().to_lower()
	role := ctx.form['role']
	if role != 'member' && role != 'admin' {
		ctx.error('Member role must be either member or admin')
		return app.organization(mut ctx, org.name)
	}
	exists, member_user := app.check_username(member_name)
	if !exists || member_user.is_blocked {
		ctx.error('No active registered user named "${member_name}" was found')
		return app.organization(mut ctx, org.name)
	}
	if app.is_org_member(org.id, member_user.id) {
		ctx.error('${member_name} is already a member of this organization')
		return app.organization(mut ctx, org.name)
	}
	app.add_org_member(org.id, member_user.id, role) or {
		ctx.error('Could not add organization member: ${err}')
		return app.organization(mut ctx, org.name)
	}
	return ctx.redirect('/${org.name}')
}

@['/organizations/:org_name/members/:member_id/remove'; post]
pub fn (mut app App) handle_remove_org_member(mut ctx Context, org_name string, member_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	org := app.get_org_by_name(org_name) or { return ctx.not_found() }
	if (app.org_member_role(org.id, ctx.user.id) or { '' }) != 'admin' {
		return ctx.not_found()
	}
	target_id := member_id.int()
	target_role := app.org_member_role(org.id, target_id) or { return ctx.not_found() }
	if target_role == 'admin' && app.count_org_admins(org.id) <= 1 {
		ctx.error('An organization must keep at least one administrator')
		return app.organization(mut ctx, org.name)
	}
	app.remove_org_member(org.id, target_id) or {
		ctx.error('Could not remove organization member: ${err}')
		return app.organization(mut ctx, org.name)
	}
	return ctx.redirect('/${org.name}')
}
