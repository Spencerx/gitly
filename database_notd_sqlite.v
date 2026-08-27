module main

import config
import db.pg
import os
import orm

type GitlyDb = pg.DB

fn connect_db(conf config.Config) !GitlyDb {
	if conninfo := first_env_opt(['GITLY_DB_CONNINFO', 'DATABASE_URL'], conf.pg.conninfo) {
		db := pg.connect_with_conninfo(conninfo, pg.PoolConfig{})!
		return GitlyDb(*db)
	}
	db := pg.connect(
		host:     first_env(['GITLY_DB_HOST', 'PGHOST'], conf.pg.host)
		port:     first_int_env(['GITLY_DB_PORT', 'PGPORT'], conf.pg.port)
		dbname:   first_env(['GITLY_DB_NAME', 'PGDATABASE'], conf.pg.dbname)
		user:     first_env(['GITLY_DB_USER', 'PGUSER'], conf.pg.user)
		password: first_env(['GITLY_DB_PASSWORD', 'PGPASSWORD'], conf.pg.password)
	)!
	return GitlyDb(*db)
}

fn db_backend_name() string {
	return 'postgres'
}

fn db_exec_values(mut db GitlyDb, query string) ![][]string {
	rows := db.exec_no_null(query)!
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
		values << row.values()
	}
	return values
}

fn db_parameter_marker(index int) string {
	return '$${index + 1}'
}

fn db_bool_value(value bool) string {
	return value.str()
}

fn db_begin_transaction(mut db GitlyDb) !orm.Tx {
	// pg.DB is pool-backed. pg.Tx owns one checked-out connection, while its
	// orm_begin method is intentionally a no-op because begin() already ran.
	mut pinned := db.begin()!
	return orm.begin(mut pinned)
}

// The transaction pins the connection which owns this advisory lock. Schema
// work can continue through the pool: every Gitly instance uses the same global
// key and must wait for the current migrator to commit or disconnect.
fn db_acquire_migration_lock(mut db GitlyDb) !orm.Tx {
	mut tx := db_begin_transaction(mut db)!
	tx.execute('select pg_advisory_xact_lock(7177956983026489)') or {
		tx.rollback() or {}
		return err
	}
	return tx
}

fn db_column_exists(mut db GitlyDb, table_name string, column_name string) !bool {
	rows := db_exec_values(mut db,
		'select column_name from information_schema.columns where table_name = ${sql_literal(table_name.to_lower())} and column_name = ${sql_literal(column_name)}')!
	return rows.len > 0
}

fn db_bool_column_type() string {
	return 'BOOLEAN NOT NULL DEFAULT false'
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

fn first_env_opt(keys []string, fallback string) ?string {
	value := first_env(keys, fallback)
	if value == '' {
		return none
	}
	return value
}

fn first_int_env(keys []string, fallback int) int {
	for key in keys {
		value := os.getenv(key)
		if value != '' {
			return value.int()
		}
	}
	return fallback
}
