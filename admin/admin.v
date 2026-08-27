module main

pub fn (mut app App) edit_user(user_id int, delete_tokens bool, is_blocked bool, is_admin bool) ! {
	if user_id <= 0 {
		return error('Invalid user')
	}
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}

	// Serialize edits which could deactivate an administrator. The previous
	// count-then-update sequence let two admins concurrently demote/block each
	// other after both observed a count of two, leaving the site with no active
	// administrator. PostgreSQL locks the matching rows; SQLite serializes the
	// eventual writer and rejects the competing transaction.
	mut active_admin_query := 'select ${sql_table('id')} from ${sql_table('User')}
		where ${sql_table('is_admin')} is true
		and ${sql_table('is_registered')} is true
		and ${sql_table('is_blocked')} is false'
	$if sqlite ? {
	} $else {
		active_admin_query += ' for update'
	}
	active_admin_rows := tx.execute(active_admin_query)!
	mut target_is_active_admin := false
	for row in active_admin_rows {
		if row.vals.len > 0 && row.vals[0].int() == user_id {
			target_is_active_admin = true
			break
		}
	}
	if target_is_active_admin && (!is_admin || is_blocked) && active_admin_rows.len <= 1 {
		return error('The site must keep at least one active administrator')
	}

	id := user_id
	sql tx {
		update User set is_admin = is_admin, is_blocked = is_blocked where id == id
	}!
	if delete_tokens {
		sql tx {
			delete from Token where user_id == id
		}!
	}
	tx.commit()!
	committed = true
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
