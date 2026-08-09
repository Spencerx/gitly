module main

pub fn (mut app App) edit_user(user_id int, delete_tokens bool, is_blocked bool, is_admin bool) ! {
	if is_admin {
		app.add_admin(user_id)!
	} else {
		app.remove_admin(user_id)!
	}

	if is_blocked {
		app.block_user(user_id)!
	} else {
		app.unblock_user(user_id)!
	}

	if delete_tokens {
		app.delete_tokens(user_id)!
	}
}

pub fn (mut app App) block_user(user_id int) ! {
	app.set_user_block_status(user_id, true)!
}

pub fn (mut app App) unblock_user(user_id int) ! {
	app.set_user_block_status(user_id, false)!
}

pub fn (mut app App) add_admin(user_id int) ! {
	app.set_user_admin_status(user_id, true)!
}

pub fn (mut app App) remove_admin(user_id int) ! {
	app.set_user_admin_status(user_id, false)!
}

fn (app App) count_admin_users() int {
	return sql app.db {
		select count from User where is_admin == true && is_registered == true && is_blocked == false
	} or { 0 }
}

pub fn (mut app App) update_gitly_settings(oauth_client_id string, oauth_client_secret string, tree_folder_size_enabled bool) ! {
	app.update_settings(oauth_client_id, oauth_client_secret, tree_folder_size_enabled)!

	app.load_settings()
}

fn (mut ctx Context) is_admin() bool {
	return ctx.logged_in && ctx.user.is_admin
}
