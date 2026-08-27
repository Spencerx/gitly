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
	// Every mutable precondition is reloaded under the transfer transaction's
	// locks. The lookup above is only an authorization-preserving 404 preflight.
	repo := app.accept_repo_transfer_atomic(transfer.id, ctx.user.id) or {
		ctx.error('There was an error while accepting the repository transfer')
		return app.repo_transfers(mut ctx, username)
	}
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
