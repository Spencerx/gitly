// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import validation

pub fn (mut app App) command_fetcher() ! {
	for {
		line := os.get_line()

		if line.starts_with('!') {
			args := line[1..].split(' ')

			if args.len > 0 {
				match args[0] {
					'adduser' {
						if args.len >= 4 {
							username := args[1].trim_space().to_lower()
							password := args[2]
							emails := args[3..].map(it.trim_space().to_lower())
							if !validation.is_username_valid(username) || password.len < 8
								|| password.len > max_password_len {
								return error('Invalid username or password (password must be 8-${max_password_len} characters)')
							}
							salt := generate_salt()
							hashed := hash_password_with_salt(password, salt)
							if hashed == '' {
								return error('Could not hash password')
							}
							app.register_user(username, hashed, salt, emails, false, false)!
							println('Added user ${username}')
						} else {
							return error('Usage: !adduser <username> <password> <email1> [email2...]')
						}
					}
					else {
						println('Commands:')
						println('	!updaterepo')
						println('	!adduser <username> <password> <email1> <email2>...')
					}
				}
			} else {
				error('Unkown syntax. Use !<command>')
			}
		} else {
			error('Unkown syntax. Use !<command>')
		}
	}
}
