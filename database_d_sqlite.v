module main

import config
import db.sqlite
import os
import orm

type GitlyDb = sqlite.DB

fn connect_db(conf config.Config) !GitlyDb {
	path := first_env(['GITLY_SQLITE_PATH', 'GITLY_DB_PATH'], conf.sqlite.path)
	mut db := sqlite.connect(path)!
	if db.busy_timeout(10000) != 0 {
		return error('failed to configure sqlite busy timeout')
	}
	db.exec('pragma journal_mode = WAL;') or { eprintln('cannot enable sqlite WAL mode: ${err}') }
	return GitlyDb(db)
}

fn db_backend_name() string {
	return 'sqlite'
}

fn db_exec_values(mut db GitlyDb, query string) ![][]string {
	rows := db.exec(query)!
	mut values := [][]string{cap: rows.len}
	for row in rows {
		values << row.vals.clone()
	}
	return values
}

fn db_exec_param_values(mut db GitlyDb, query string, params []string) ![][]string {
	rows := db.exec_param_many(query, params)!
	mut values := [][]string{cap: rows.len}
	for row in rows {
		values << row.vals.clone()
	}
	return values
}

fn db_parameter_marker(_index int) string {
	return '?'
}

fn db_bool_value(value bool) string {
	return if value { '1' } else { '0' }
}

fn db_begin_transaction(mut db GitlyDb) !orm.Tx {
	return orm.begin(mut db)
}

// db_acquire_migration_lock takes SQLite's single-writer reservation before
// schema inspection begins. The lock row is intentionally updated even when it
// already exists so concurrent Gitly processes cannot both pass a
// check-then-ALTER migration.
fn db_acquire_migration_lock(mut db GitlyDb) !orm.Tx {
	mut tx := db_begin_transaction(mut db)!
	tx.execute('create table if not exists "__gitly_migration_lock" ("id" integer primary key)') or {
		tx.rollback() or {}
		return err
	}
	tx.execute('insert or ignore into "__gitly_migration_lock" ("id") values (1)') or {
		tx.rollback() or {}
		return err
	}
	tx.execute('update "__gitly_migration_lock" set "id" = "id" where "id" = 1') or {
		tx.rollback() or {}
		return err
	}
	return tx
}

fn db_column_exists(mut db GitlyDb, table_name string, column_name string) !bool {
	rows := db_exec_values(mut db, 'pragma table_info(${sql_table(table_name)})')!
	for row in rows {
		if row.len > 1 && row[1] == column_name {
			return true
		}
	}
	return false
}

fn db_bool_column_type() string {
	return 'INTEGER NOT NULL DEFAULT 0'
}

fn first_env(keys []string, fallback string) string {
	for key in keys {
		value := os.getenv(key)
		if value != '' {
			return value
		}
	}
	return fallback
}
