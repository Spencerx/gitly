module main

import veb

// reconnect_db drops the current DB handle and opens a fresh connection.
// Used to recover from stale connections (e.g. an idle Postgres connection
// dropped by NAT or by PG's idle_session_timeout). v's db.pg has no built-in
// reconnect, so without this the process keeps using a dead handle until restart.
pub fn (mut app App) reconnect_db() ! {
	app.db.close() or {}
	app.db = connect_db(app.config)!
}

// get_users_count_with_reconnect retries the user count query once after
// reconnecting on failure. This is the recovery path for the specific bug
// where a dead DB handle made get_users_count() silently return 0 and the
// site rendered the "welcome / register" page until systemd restart.
pub fn (mut app App) get_users_count_with_reconnect() !int {
	if count := app.get_users_count() {
		return count
	} else {
		app.warn('db query failed, attempting reconnect: ${err}')
		app.reconnect_db() or { return error('db unavailable; reconnect failed: ${err}') }
		return app.get_users_count()!
	}
}

// db_error renders a 503 response describing a database failure.
// We render an explicit page rather than letting callers fall back to a
// misleading default (e.g. redirecting to /register on a swallowed error).
pub fn (mut ctx Context) db_error(_err IError) veb.Result {
	ctx.res.set_status(.service_unavailable)
	body := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Gitly — database unavailable</title></head><body style="font-family:sans-serif;max-width:640px;margin:4em auto;padding:0 1em;"><h1>Database unavailable</h1><p>Gitly could not reach its database. This is usually transient — please try again in a moment.</p></body></html>'
	return ctx.html(body)
}

fn sql_table(name string) string {
	return '"' + name.to_lower().replace('"', '""') + '"'
}

fn sql_literal(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn sql_like_pattern(value string) string {
	return sql_literal('%' + value + '%')
}

// db_insert_returning_id performs an INSERT and obtains its generated id from
// that same database statement. A separate last_insert_rowid()/LASTVAL() query
// is connection-local and can observe another request's insert when the shared
// SQLite connection or PostgreSQL pool is busy.
fn db_insert_returning_id(mut db GitlyDb, table_name string, columns []string, values []string) !int {
	if !table_name.is_identifier() || columns.len == 0 || columns.len != values.len {
		return error('invalid insert returning id request')
	}
	mut quoted_columns := []string{cap: columns.len}
	mut placeholders := []string{cap: columns.len}
	for i, column in columns {
		if !column.is_identifier() {
			return error('invalid insert column')
		}
		quoted_columns << sql_table(column)
		placeholders << db_parameter_marker(i)
	}
	query := 'insert into ${sql_table(table_name)} (${quoted_columns.join(', ')}) values (${placeholders.join(', ')}) returning id'
	rows := db_exec_param_values(mut db, query, values)!
	if rows.len != 1 || rows[0].len != 1 {
		return error('insert did not return an id')
	}
	id := rows[0][0].int()
	if id <= 0 {
		return error('insert returned an invalid id')
	}
	return id
}
