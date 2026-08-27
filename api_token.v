// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import crypto.sha256
import crypto.rand
import encoding.hex

const api_token_scope_api = 'api'
const api_token_scope_read_api = 'read_api'
const api_token_scope_read_repository = 'read_repository'
const api_token_scope_write_repository = 'write_repository'
const api_token_max_expiry_days = 365
const api_token_default_expiry_days = 30

struct ApiToken {
	id int @[primary; sql: serial]
mut:
	user_id      int
	name         string
	token_hash   string
	scopes       string
	expires_at   int
	created_at   int
	last_used_at int
}

fn api_token_scope_is_known(scope string) bool {
	return scope in [api_token_scope_api, api_token_scope_read_api, api_token_scope_read_repository,
		api_token_scope_write_repository]
}

fn normalize_api_token_scopes(requested []string) !string {
	mut selected := map[string]bool{}
	for raw_scope in requested {
		scope := raw_scope.trim_space().to_lower()
		if !api_token_scope_is_known(scope) {
			return error('invalid API token scope')
		}
		selected[scope] = true
	}
	mut normalized := []string{}
	for scope in [api_token_scope_api, api_token_scope_read_api, api_token_scope_read_repository,
		api_token_scope_write_repository] {
		if selected[scope] {
			normalized << scope
		}
	}
	if normalized.len == 0 {
		return error('at least one API token scope is required')
	}
	return normalized.join(',')
}

fn (token ApiToken) is_expired(now int) bool {
	return token.expires_at > 0 && token.expires_at <= now
}

fn (token ApiToken) allows_scope(required_scope string, now int) bool {
	if token.is_expired(now) || !api_token_scope_is_known(required_scope) {
		return false
	}
	scopes := token.scopes.split(',').map(it.trim_space())
	if api_token_scope_api in scopes {
		return true
	}
	return match required_scope {
		api_token_scope_read_api {
			api_token_scope_read_api in scopes
		}
		api_token_scope_api {
			false
		}
		api_token_scope_read_repository {
			api_token_scope_read_repository in scopes || api_token_scope_write_repository in scopes
		}
		api_token_scope_write_repository {
			api_token_scope_write_repository in scopes
		}
		else {
			false
		}
	}
}

fn (token ApiToken) expiry_description() string {
	if token.expires_at == 0 {
		return 'Never (legacy token)'
	}
	if token.is_expired(int(time.now().unix())) {
		return 'Expired ${time.unix(token.expires_at).format_ss()}'
	}
	return time.unix(token.expires_at).format_ss()
}

fn hash_api_token(plain string) string {
	return sha256.sum(plain.bytes()).hex()
}

fn generate_api_token_plaintext() string {
	buf := rand.bytes(24) or { return '' }
	return 'glt_' + hex.encode(buf)
}

// add_api_token retains the historical unscoped/no-expiry behavior for trusted
// internal callers and existing integrations. User-facing creation always uses
// add_scoped_api_token, which requires an expiry and explicit scopes.
fn (mut app App) add_api_token(user_id int, name string) !(int, string) {
	return app.add_api_token_with_policy(user_id, name, [api_token_scope_api], 0, true)
}

fn (mut app App) add_scoped_api_token(user_id int, name string, requested_scopes []string, expires_at int) !(int, string) {
	return app.add_api_token_with_policy(user_id, name, requested_scopes, expires_at, false)
}

fn (mut app App) add_api_token_with_policy(user_id int, name string, requested_scopes []string, expires_at int, allow_no_expiry bool) !(int, string) {
	if user_id <= 0 || !valid_short_name(name) {
		return error('invalid API token owner or name')
	}
	scopes := normalize_api_token_scopes(requested_scopes)!
	now := int(time.now().unix())
	max_expires_at := now + api_token_max_expiry_days * 24 * 60 * 60
	if (!allow_no_expiry && expires_at == 0) || expires_at < 0
		|| (expires_at > 0 && (expires_at <= now || expires_at > max_expires_at)) {
		return error('API token expiry must be within the next ${api_token_max_expiry_days} days')
	}
	plain := generate_api_token_plaintext()
	if plain == '' {
		return error('could not generate a secure API token')
	}
	id := db_insert_returning_id(mut app.db, 'ApiToken', ['user_id', 'name', 'token_hash', 'scopes',
		'expires_at', 'created_at', 'last_used_at'], [user_id.str(), name, hash_api_token(plain),
		scopes, expires_at.str(), now.str(), '0'])!
	return id, plain
}

fn (mut app App) list_user_api_tokens(user_id int) []ApiToken {
	return sql app.db {
		select from ApiToken where user_id == user_id order by id desc
	} or { []ApiToken{} }
}

fn (mut app App) delete_api_token(user_id int, id int) ! {
	sql app.db {
		delete from ApiToken where id == id && user_id == user_id
	}!
}

fn (mut app App) find_valid_api_token(plain string, user_id int, required_scope string) ?ApiToken {
	if !plain.starts_with('glt_') || plain.len > max_password_len
		|| !api_token_scope_is_known(required_scope) {
		return none
	}
	if user_id < 0 {
		return none
	}
	hashed := hash_api_token(plain)
	rows := if user_id > 0 {
		target_user_id := user_id
		sql app.db {
			select from ApiToken where token_hash == hashed && user_id == target_user_id limit 1
		} or { []ApiToken{} }
	} else {
		sql app.db {
			select from ApiToken where token_hash == hashed limit 1
		} or { []ApiToken{} }
	}
	if rows.len == 0 {
		return none
	}
	token := rows.first()
	if !token.allows_scope(required_scope, int(time.now().unix())) {
		return none
	}
	return token
}

fn (mut app App) touch_api_token(token_id int) {
	now := int(time.now().unix())
	sql app.db {
		update ApiToken set last_used_at = now where id == token_id
	} or {}
}

// api_token_authenticates_user verifies that a plaintext token belongs to the
// user named in a Basic-auth request and has the scope needed by that Git
// operation. Keeping the user constraint in the query prevents a token for one
// account from being paired with another username.
fn (mut app App) api_token_authenticates_user(plain string, user_id int, required_scope string) bool {
	if user_id <= 0 {
		return false
	}
	token := app.find_valid_api_token(plain, user_id, required_scope) or { return false }
	app.touch_api_token(token.id)
	return true
}

fn (mut app App) user_for_api_token(plain string, required_scope string) ?User {
	token := app.find_valid_api_token(plain, 0, required_scope) or { return none }
	user := app.get_user_by_id(token.user_id) or { return none }
	if !user.is_registered || user.is_blocked {
		return none
	}
	app.touch_api_token(token.id)
	return user
}
