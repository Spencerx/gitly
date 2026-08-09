// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import encoding.base32
import encoding.binary
import crypto.hmac
import crypto.sha1
import crypto.rand as crypto_rand

struct TwoFactor {
	id int @[primary; sql: serial]
mut:
	user_id    int
	secret     string
	is_enabled bool
	created_at int
}

const totp_period = 30
const totp_digits = 6
const totp_issuer = 'Gitly'

fn (mut app App) find_two_factor(user_id int) ?TwoFactor {
	rows := sql app.db {
		select from TwoFactor where user_id == user_id limit 1
	} or { []TwoFactor{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) upsert_two_factor(user_id int, secret string, is_enabled bool) ! {
	if existing := app.find_two_factor(user_id) {
		id := existing.id
		sql app.db {
			update TwoFactor set secret = secret, is_enabled = is_enabled where id == id
		}!
		return
	}
	tf := TwoFactor{
		user_id:    user_id
		secret:     secret
		is_enabled: is_enabled
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert tf into TwoFactor
	}!
}

fn (mut app App) delete_two_factor(user_id int) ! {
	sql app.db {
		delete from TwoFactor where user_id == user_id
	}!
}

fn (mut app App) user_has_two_factor(user_id int) bool {
	tf := app.find_two_factor(user_id) or { return false }
	return tf.is_enabled
}

fn generate_totp_secret() !string {
	buf := crypto_rand.bytes(20)!
	enc := base32.encode_to_string(buf)
	return enc.trim_right('=')
}

fn decode_base32_secret(secret string) ![]u8 {
	mut padded := secret.to_upper().replace(' ', '')
	for padded.len % 8 != 0 {
		padded += '='
	}
	return base32.decode(padded.bytes())!
}

fn hotp(key []u8, counter u64) int {
	mut buf := []u8{len: 8}
	binary.big_endian_put_u64(mut buf, counter)
	mac := hmac.new(key, buf, sha1.sum, sha1.block_size)
	offset := int(mac[mac.len - 1] & 0x0f)
	bin := ((u32(mac[offset]) & 0x7f) << 24) | ((u32(mac[offset + 1]) & 0xff) << 16) | ((u32(mac[
		offset + 2]) & 0xff) << 8) | (u32(mac[offset + 3]) & 0xff)
	mut modulus := u32(1)
	for _ in 0 .. totp_digits {
		modulus *= 10
	}
	return int(bin % modulus)
}

fn totp_code_for(secret string, t i64) !string {
	key := decode_base32_secret(secret)!
	counter := u64(t / totp_period)
	code := hotp(key, counter)
	mut s := code.str()
	for s.len < totp_digits {
		s = '0' + s
	}
	return s
}

fn verify_totp(secret string, code string) bool {
	if code.len != totp_digits {
		return false
	}
	now := time.now().unix()
	for offset in [i64(-1), 0, 1] {
		expected := totp_code_for(secret, now + offset * totp_period) or { continue }
		if hmac.equal(expected.bytes(), code.bytes()) {
			return true
		}
	}
	return false
}

fn totp_provisioning_uri(username string, secret string) string {
	label := '${totp_issuer}:${username}'
	return 'otpauth://totp/${label}?secret=${secret}&issuer=${totp_issuer}&algorithm=SHA1&digits=${totp_digits}&period=${totp_period}'
}
