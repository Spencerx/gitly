// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import time
import crypto.hmac
import crypto.sha256
import encoding.hex

const two_factor_pending_cookie = 'pending_2fa'
const two_factor_pending_ttl = 300 // seconds

fn (mut app App) pending_2fa_key(user User) []u8 {
	return '${user.password}:${user.salt}'.bytes()
}

fn (mut app App) sign_pending_2fa(user User, expires i64) string {
	payload := '${user.id}:${expires}'
	mac := hmac.new(app.pending_2fa_key(user), payload.bytes(), sha256.sum, sha256.block_size)
	return '${payload}:${hex.encode(mac)}'
}

fn (mut app App) verify_pending_2fa(token string) ?User {
	parts := token.split(':')
	if parts.len != 3 {
		return none
	}
	user_id := parts[0].int()
	expires := parts[1].i64()
	sig := parts[2]
	if expires < time.now().unix() {
		return none
	}
	user := app.get_user_by_id(user_id) or { return none }
	payload := '${user_id}:${expires}'
	expected := hmac.new(app.pending_2fa_key(user), payload.bytes(), sha256.sum, sha256.block_size)
	provided := hex.decode(sig) or { return none }
	if !hmac.equal(expected, provided) {
		return none
	}
	return user
}

@['/login/2fa']
pub fn (mut app App) two_factor_prompt(mut ctx Context) veb.Result {
	pending := ctx.get_cookie(two_factor_pending_cookie) or { return ctx.redirect_to_login() }
	app.verify_pending_2fa(pending) or { return ctx.redirect_to_login() }
	return $veb.html('templates/two_factor_login.html')
}

@['/login/2fa'; post]
pub fn (mut app App) handle_two_factor_login(mut ctx Context, code string) veb.Result {
	pending := ctx.get_cookie(two_factor_pending_cookie) or { return ctx.redirect_to_login() }
	user := app.verify_pending_2fa(pending) or { return ctx.redirect_to_login() }
	tf := app.find_two_factor(user.id) or { return ctx.redirect_to_login() }
	if !tf.is_enabled || !verify_totp(tf.secret, code.trim_space()) {
		ctx.error('Invalid verification code')
		return $veb.html('templates/two_factor_login.html')
	}
	ctx.set_cookie(
		name:      two_factor_pending_cookie
		value:     ''
		path:      '/'
		max_age:   -1
		http_only: true
		same_site: .same_site_strict_mode
		secure:    app.config.cookie_secure
	)
	app.auth_user(mut ctx, user, ctx.ip()) or {
		ctx.error('There was an error while logging in')
		return ctx.redirect_to_login()
	}
	app.add_security_log(user_id: user.id, kind: .logged_in) or { app.info(err.str()) }
	return ctx.redirect('/${user.username}')
}

@['/:username/settings/2fa']
pub fn (mut app App) view_two_factor_settings(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	tf := app.find_two_factor(ctx.user.id) or {
		TwoFactor{
			user_id: ctx.user.id
		}
	}
	enabled := tf.is_enabled
	mut secret := ''
	mut provisioning_uri := ''
	if !enabled {
		secret = if tf.secret == '' {
			generate_totp_secret() or {
				return ctx.server_error('Could not generate a secure two-factor secret')
			}
		} else {
			tf.secret
		}
		app.upsert_two_factor(ctx.user.id, secret, false) or {}
		provisioning_uri = totp_provisioning_uri(username, secret)
	}
	return $veb.html('templates/two_factor_settings.html')
}

@['/:username/settings/2fa/enable'; post]
pub fn (mut app App) handle_enable_two_factor(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	code := ctx.form['code'].trim_space()
	tf := app.find_two_factor(ctx.user.id) or { return ctx.redirect('/${username}/settings/2fa') }
	if !verify_totp(tf.secret, code) {
		ctx.error('Invalid verification code')
		return ctx.redirect('/${username}/settings/2fa')
	}
	app.upsert_two_factor(ctx.user.id, tf.secret, true) or {}
	return ctx.redirect('/${username}/settings/2fa')
}

@['/:username/settings/2fa/disable'; post]
pub fn (mut app App) handle_disable_two_factor(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in || ctx.user.username != username {
		return ctx.redirect_to_index()
	}
	app.delete_two_factor(ctx.user.id) or {}
	return ctx.redirect('/${username}/settings/2fa')
}
