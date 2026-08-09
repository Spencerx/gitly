// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

@['/:username/settings/repo-transfers']
pub fn (mut app App) repo_transfers(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	transfers := app.find_repo_transfers_for_user(ctx.user.id)
	return $veb.html('templates/user/repo_transfers.html')
}

@['/:username/settings/repo-transfers/:id/accept'; post]
pub fn (mut app App) accept_repo_transfer(mut ctx Context, username string, id string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	transfer := app.find_repo_transfer(id.int()) or { return ctx.not_found() }
	if transfer.recipient_id != ctx.user.id {
		return ctx.not_found()
	}
	repo := app.find_repo_by_id(transfer.repo_id) or {
		app.delete_repo_transfer(transfer.id) or {}
		return ctx.not_found()
	}
	if app.user_has_repo(ctx.user.id, repo.name) {
		ctx.error('You already own a repository named ${repo.name}')
		return app.repo_transfers(mut ctx, username)
	}
	if !ctx.is_admin() && app.get_count_user_repos(ctx.user.id) >= max_user_repos {
		ctx.error('You have reached the repository limit')
		return app.repo_transfers(mut ctx, username)
	}
	app.move_repo_to_user(repo, ctx.user) or {
		ctx.error('There was an error while accepting the repository transfer')
		return app.repo_transfers(mut ctx, username)
	}
	app.delete_repo_transfer(transfer.id) or { app.info('failed to clear repo transfer: ${err}') }
	return ctx.redirect('/${ctx.user.username}/${repo.name}')
}

@['/:username/settings/repo-transfers/:id/decline'; post]
pub fn (mut app App) decline_repo_transfer(mut ctx Context, username string, id string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	transfer := app.find_repo_transfer(id.int()) or { return ctx.not_found() }
	if transfer.recipient_id != ctx.user.id {
		return ctx.not_found()
	}
	app.delete_repo_transfer(transfer.id) or {
		ctx.error('There was an error while declining the repository transfer')
		return app.repo_transfers(mut ctx, username)
	}
	return ctx.redirect('/${username}/settings/repo-transfers')
}
