// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.rand
import crypto.sha256
import encoding.hex
import time

const session_ttl = 30 * 24 * 60 * 60

struct Token {
	id         int @[primary; sql: serial]
	user_id    int
	value      string @[unique]
	ip         string
	created_at int
	expires_at int
}

fn (mut app App) add_token(user_id int, ip string) !string {
	plain := hex.encode(rand.bytes(32)!)
	now := int(time.now().unix())

	token := Token{
		user_id:    user_id
		value:      hash_session_token(plain)
		ip:         ip
		created_at: now
		expires_at: now + session_ttl
	}

	sql app.db {
		insert token into Token
	}!

	return plain
}

fn (mut app App) get_token(value string) ?Token {
	if value == '' {
		return none
	}
	hashed := hash_session_token(value)
	mut tokens := sql app.db {
		select from Token where value == hashed limit 1
	} or { []Token{} }
	// Transparently accept pre-migration plaintext sessions once and replace
	// the stored secret with a hash. Existing users are not logged out on
	// upgrade, while a later database leak cannot be replayed as a session.
	mut legacy := false
	if tokens.len == 0 {
		tokens = sql app.db {
			select from Token where value == value limit 1
		} or { []Token{} }
		legacy = tokens.len > 0
	}
	if tokens.len == 0 {
		return none
	}
	token := tokens.first()
	now := int(time.now().unix())
	if token.expires_at > 0 && token.expires_at < now {
		id := token.id
		sql app.db {
			delete from Token where id == id
		} or {}
		return none
	}
	if legacy || token.expires_at == 0 {
		id := token.id
		expires_at := now + session_ttl
		sql app.db {
			update Token set value = hashed, created_at = now, expires_at = expires_at where id == id
		} or { return none }
	}
	return token
}

fn hash_session_token(plain string) string {
	return sha256.sum(plain.bytes()).hex()
}

fn (mut app App) delete_token(value string) ! {
	if value == '' {
		return
	}
	hashed := hash_session_token(value)
	sql app.db {
		delete from Token where value == hashed
	}!
	// Also clear a legacy plaintext row when logging out during migration.
	sql app.db {
		delete from Token where value == value
	}!
}

fn (mut app App) delete_tokens(user_id int) ! {
	sql app.db {
		delete from Token where user_id == user_id
	}!
}
