module main

import config
import os

fn test_sql_table_quotes_identifiers() {
	assert sql_table('Commit') == '"commit"'
	assert sql_table('weird"name') == '"weird""name"'
}

fn test_sql_literal_escapes_single_quotes() {
	assert sql_literal("bob's repo") == "'bob''s repo'"
}

fn test_sql_like_pattern_wraps_and_escapes_query() {
	assert sql_like_pattern("bob's") == "'%bob''s%'"
}

struct InsertIdProbeResult {
	id    int
	value string
	err   string
}

struct InsertBoolProbe {
	id      int @[primary; sql: serial]
	enabled bool
}

fn insert_id_probe(db_path string, index int) InsertIdProbeResult {
	conf := config.Config{
		sqlite: config.SqliteConfig{
			path: db_path
		}
	}
	mut db := connect_db(conf) or { return InsertIdProbeResult{
		err: err.str()
	} }
	defer {
		db.close() or {}
	}
	value := "request ${index}'s value"
	id := db_insert_returning_id(mut db, 'InsertIdProbe', ['value'], [value]) or {
		return InsertIdProbeResult{
			err: err.str()
		}
	}
	return InsertIdProbeResult{
		id:    id
		value: value
	}
}

fn test_insert_returning_id_stays_attached_to_its_concurrent_insert() {
	$if sqlite ? {
		db_path := os.join_path(os.temp_dir(), 'gitly_insert_id_${os.getpid()}.sqlite')
		for suffix in ['', '-shm', '-wal'] {
			os.rm(db_path + suffix) or {}
		}
		defer {
			for suffix in ['', '-shm', '-wal'] {
				os.rm(db_path + suffix) or {}
			}
		}
		conf := config.Config{
			sqlite: config.SqliteConfig{
				path: db_path
			}
		}
		mut setup_db := connect_db(conf)!
		setup_db.exec('create table "insertidprobe" (id integer primary key autoincrement, value text not null)')!
		setup_db.close()!

		mut workers := []thread InsertIdProbeResult{cap: 16}
		for i in 0 .. 16 {
			workers << spawn insert_id_probe(db_path, i)
		}
		results := workers.wait()

		mut verify_db := connect_db(conf)!
		defer {
			verify_db.close() or {}
		}
		mut ids := map[int]bool{}
		for result in results {
			assert result.err == ''
			assert result.id > 0
			assert result.id !in ids
			ids[result.id] = true
			rows := db_exec_param_values(mut verify_db,
				'select value from "insertidprobe" where id = ?', [
				result.id.str(),
			])!
			assert rows.len == 1
			assert rows[0][0] == result.value
		}
	} $else {
		assert true
	}
}

fn test_database_transaction_rollback_restores_previous_state() {
	$if sqlite ? {
		conf := config.Config{
			sqlite: config.SqliteConfig{
				path: ':memory:'
			}
		}
		mut db := connect_db(conf)!
		defer {
			db.close() or {}
		}
		db.exec('create table "transactionprobe" (id integer primary key autoincrement, value text not null)')!
		db.exec('insert into "transactionprobe" (value) values (\'before\')')!

		mut tx := db_begin_transaction(mut db)!
		tx.execute('delete from "transactionprobe"')!
		tx.execute('insert into "transactionprobe" (value) values (\'during\')')!
		tx.rollback()!

		rows := db_exec_values(mut db, 'select value from "transactionprobe" order by id')!
		assert rows == [['before']]
	} $else {
		assert true
	}
}

fn test_insert_returning_id_preserves_orm_boolean_semantics() {
	$if sqlite ? {
		conf := config.Config{
			sqlite: config.SqliteConfig{
				path: ':memory:'
			}
		}
		mut db := connect_db(conf)!
		defer {
			db.close() or {}
		}
		sql db {
			create table InsertBoolProbe
		}!
		false_id := db_insert_returning_id(mut db, 'InsertBoolProbe', ['enabled'], [
			db_bool_value(false),
		])!
		true_id := db_insert_returning_id(mut db, 'InsertBoolProbe', ['enabled'], [
			db_bool_value(true),
		])!
		false_rows := sql db {
			select from InsertBoolProbe where enabled == false
		}!
		true_rows := sql db {
			select from InsertBoolProbe where enabled == true
		}!
		assert false_rows.len == 1
		assert false_rows[0].id == false_id
		assert !false_rows[0].enabled
		assert true_rows.len == 1
		assert true_rows[0].id == true_id
		assert true_rows[0].enabled
	} $else {
		assert true
	}
}

fn test_id_returning_mutations_round_trip_the_inserted_rows() {
	$if sqlite ? {
		conf := config.Config{
			storage_secret:       '0123456789abcdef0123456789abcdef'
			mirror_allowed_hosts: ['example.com']
			sqlite:               config.SqliteConfig{
				path: ':memory:'
			}
		}
		mut app := App{
			db:     connect_db(conf)!
			config: conf
		}
		defer {
			app.db.close() or {}
		}
		app.create_tables()!

		issue_id := app.add_imported_issue_returning_id(10, 20, "issue's title", 'body', 100)!
		issue := app.find_issue_by_id(issue_id) or { panic('inserted issue was not found') }
		assert issue.title == "issue's title"
		assert !issue.is_pr

		discussion_id := app.add_discussion(10, 20, "discussion's title", 'body', 'qa')!
		discussion := app.find_discussion(discussion_id) or {
			panic('inserted discussion was not found')
		}
		assert discussion.title == "discussion's title"
		assert !discussion.is_locked

		milestone_id := app.add_milestone(10, "milestone's title", 'description', 0)!
		milestone := app.find_milestone(milestone_id) or {
			panic('inserted milestone was not found')
		}
		assert milestone.title == "milestone's title"
		assert !milestone.is_closed

		pr_id := app.add_pull_request_with_created_at(10, 20, "PR's title", 'description',
			'feature', 'main', 100)!
		pr := app.find_pull_request_by_id(pr_id) or { panic('inserted pull request was not found') }
		assert pr.title == "PR's title"

		review_id := app.add_pr_review(pr_id, 20, 1, "reviewer's note")!
		reviews := app.get_pr_reviews(pr_id)
		assert reviews.any(it.id == review_id && it.body == "reviewer's note")

		project_id := app.add_project(10, "project's name", 'description')!
		project := app.find_project(project_id) or { panic('inserted project was not found') }
		assert project.name == "project's name"
		assert app.list_project_columns(project_id).len == 3

		member_id := app.add_project_member(10, 20, 'developer')!
		member := app.find_project_member_by_id(10, member_id) or {
			panic('inserted project member was not found')
		}
		assert member.user_id == 20

		rule_id := app.protect_branch(10, 'release/*', project_access_maintainer,
			project_access_developer)!
		rule := app.find_protected_branch_by_id(10, rule_id) or {
			panic('inserted protected branch was not found')
		}
		assert rule.pattern == 'release/*'

		app.add_commit(10, 30, '0123456789abcdef', "author's name", 20, "commit's message", 100)!
		commit := app.find_repo_commit_by_hash(10, '0123456789abcdef')
		assert commit.id > 0
		assert commit.author == "author's name"

		token_id, plain_token := app.add_api_token(20, "token's name")!
		assert plain_token.starts_with('glt_')
		tokens := app.list_user_api_tokens(20)
		assert tokens.any(it.id == token_id && it.name == "token's name")

		mirror_id := app.add_repo_mirror(10, 20, 'https://example.com/repo.git', '', '', '', '',
			'pull', false, false, 5)!
		mirror := app.find_repo_mirror(mirror_id) or { panic('inserted mirror was not found') }
		assert mirror.enabled
		assert !mirror.overwrite_diverged
		assert !mirror.only_protected
	} $else {
		assert true
	}
}
