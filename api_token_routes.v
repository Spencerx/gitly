// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

const new_api_token_cookie = 'new_api_token'

@['/:username/settings/api-tokens']
pub fn (mut app App) view_api_tokens(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	tokens := app.list_user_api_tokens(ctx.user.id)
	new_token := ctx.get_cookie(new_api_token_cookie) or { '' }
	if new_token != '' {
		ctx.set_cookie(
			name:      new_api_token_cookie
			value:     ''
			path:      '/${username}/settings/api-tokens'
			max_age:   -1
			http_only: true
			same_site: .same_site_strict_mode
			secure:    app.config.cookie_secure
		)
	}
	return $veb.html('templates/api_tokens.html')
}

@['/:username/settings/api-tokens'; post]
pub fn (mut app App) handle_create_api_token(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	name := ctx.form['name'].trim_space()
	if !valid_short_name(name) {
		return ctx.redirect('/${username}/settings/api-tokens')
	}
	_, plain := app.add_api_token(ctx.user.id, name) or {
		return ctx.redirect('/${username}/settings/api-tokens')
	}
	// Deliver the token once without putting it in a URL, where browser history,
	// reverse-proxy access logs, referrers, and analytics could retain it.
	ctx.set_cookie(
		name:      new_api_token_cookie
		value:     plain
		path:      '/${username}/settings/api-tokens'
		max_age:   60
		http_only: true
		same_site: .same_site_strict_mode
		secure:    app.config.cookie_secure
	)
	return ctx.redirect('/${username}/settings/api-tokens')
}

@['/:username/settings/api-tokens/:id/delete'; post]
pub fn (mut app App) handle_delete_api_token(mut ctx Context, username string, id string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	app.delete_api_token(ctx.user.id, id.int()) or {}
	return ctx.redirect('/${username}/settings/api-tokens')
}
