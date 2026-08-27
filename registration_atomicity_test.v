module main

import config
import os

struct RegistrationRaceResult {
	username   string
	registered bool
	err        string
}

struct GitHubRegistrationRaceResult {
	user_id          int
	newly_registered bool
	err              string
}

fn registration_atomicity_config(root string) config.Config {
	return config.Config{
		repo_storage_path: root
		archive_path:      root
		avatars_path:      root
		sqlite:            config.SqliteConfig{
			path: os.join_path(root, 'test.sqlite')
		}
	}
}

fn registration_atomicity_app(conf config.Config) !App {
	return App{
		db:     connect_db(conf)!
		config: conf
	}
}

fn registration_race_worker(root string, username string, start chan bool) RegistrationRaceResult {
	_ := <-start
	conf := registration_atomicity_config(root)
	mut app := registration_atomicity_app(conf) or {
		return RegistrationRaceResult{
			username: username
			err:      err.msg()
		}
	}
	defer {
		app.db.close() or {}
	}
	app.register_user(username, 'password-hash', 'salt', ['shared@example.com'], false, false) or {
		return RegistrationRaceResult{
			username: username
			err:      err.msg()
		}
	}
	return RegistrationRaceResult{
		username:   username
		registered: true
	}
}

fn github_registration_race_worker(root string, start chan bool) GitHubRegistrationRaceResult {
	_ := <-start
	conf := registration_atomicity_config(root)
	mut app := registration_atomicity_app(conf) or {
		return GitHubRegistrationRaceResult{
			err: err.msg()
		}
	}
	defer {
		app.db.close() or {}
	}
	resolution := app.resolve_github_oauth_identity(GitHubOAuthIdentity{
		id:             90_003
		username:       'ConcurrentOctocat'
		verified_email: 'concurrent-oauth@example.com'
		avatar:         'https://avatars.githubusercontent.com/u/90003?v=4'
	}) or { return GitHubRegistrationRaceResult{
		err: err.msg()
	} }
	return GitHubRegistrationRaceResult{
		user_id:          resolution.user.id
		newly_registered: resolution.newly_registered
	}
}

fn test_registration_rolls_back_user_and_prior_emails_when_an_email_insert_fails() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_registration_rollback_${os.getpid()}')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := registration_atomicity_config(root)
		mut app := registration_atomicity_app(conf)!
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.migrate_tables()!
		app.db.exec("create trigger fail_registration_email before insert on ${sql_table('Email')}
			when NEW.email = 'reject@example.com'
			begin select raise(abort, 'forced email failure'); end")!

		mut failed := false
		app.register_user('atomic-user', 'password-hash', 'salt', [
			'accepted@example.com',
			'reject@example.com',
		], false, false) or { failed = true }
		assert failed
		assert db_exec_values(mut app.db,
			"select count(*) from ${sql_table('User')} where username = 'atomic-user'")! == [
			['0'],
		]
		assert db_exec_values(mut app.db,
			"select count(*) from ${sql_table('Email')} where email in ('accepted@example.com', 'reject@example.com')")! == [
			['0'],
		]
		assert !os.exists(os.join_path(root, 'atomic-user'))

		app.db.exec('drop trigger fail_registration_email')!
		assert app.register_user('atomic-user', 'password-hash', 'salt', [
			'accepted@example.com',
			'reject@example.com',
		], false, false)!
		assert db_exec_values(mut app.db,
			"select count(*) from ${sql_table('Email')} where email in ('accepted@example.com', 'reject@example.com')")! == [
			['2'],
		]
	} $else {
		assert true
	}
}

fn test_concurrent_registration_with_one_email_leaves_only_the_winner() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_registration_race_${os.getpid()}')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := registration_atomicity_config(root)
		mut setup_app := registration_atomicity_app(conf)!
		setup_app.create_tables()!
		setup_app.migrate_tables()!
		setup_app.db.close()!

		start := chan bool{cap: 2}
		worker_a := spawn registration_race_worker(root, 'racer-a', start)
		worker_b := spawn registration_race_worker(root, 'racer-b', start)
		start <- true
		start <- true
		results := [worker_a.wait(), worker_b.wait()]
		assert results.filter(it.registered).len == 1
		assert results.filter(!it.registered).len == 1

		mut verify_app := registration_atomicity_app(conf)!
		defer {
			verify_app.db.close() or {}
		}
		users := db_exec_values(mut verify_app.db,
			"select username from ${sql_table('User')} where username in ('racer-a', 'racer-b')")!
		assert users.len == 1
		assert users[0][0] == results.filter(it.registered)[0].username
		assert db_exec_values(mut verify_app.db,
			"select count(*) from ${sql_table('Email')} where email = 'shared@example.com'")! == [
			['1'],
		]
	} $else {
		assert true
	}
}

fn test_new_github_registration_rolls_back_its_shadow_when_email_insert_fails() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_github_registration_rollback_${os.getpid()}')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := registration_atomicity_config(root)
		mut app := registration_atomicity_app(conf)!
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.migrate_tables()!
		app.db.exec("create trigger fail_github_registration_email before insert on ${sql_table('Email')}
			when NEW.email = 'oauth-failure@example.com'
			begin select raise(abort, 'forced GitHub email failure'); end")!
		identity := GitHubOAuthIdentity{
			id:             90_001
			username:       'AtomicOctocat'
			verified_email: 'oauth-failure@example.com'
			avatar:         'https://avatars.githubusercontent.com/u/90001?v=4'
		}

		mut failed := false
		app.resolve_github_oauth_identity(identity) or { failed = true }
		assert failed
		assert app.get_user_by_username('atomicoctocat') == none
		assert app.get_user_by_github_id(identity.id) == none
		assert app.get_user_by_email(identity.verified_email) == none
		assert !os.exists(os.join_path(root, 'atomicoctocat'))
		assert db_exec_values(mut app.db,
			'select count(*) from ${sql_table('User')} where ${sql_table('is_bootstrap_admin')} is true')! == [
			['0'],
		]

		app.db.exec('drop trigger fail_github_registration_email')!
		resolution := app.resolve_github_oauth_identity(identity)!
		assert resolution.newly_registered
		assert resolution.user.github_id == identity.id
		assert resolution.user.is_registered
		assert (app.get_user_by_id(resolution.user.id) or { panic('GitHub user missing') }).is_bootstrap_admin
	} $else {
		assert true
	}
}

fn test_github_shadow_upgrade_rolls_back_identity_and_activation_together() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_github_shadow_rollback_${os.getpid()}')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := registration_atomicity_config(root)
		mut app := registration_atomicity_app(conf)!
		defer {
			app.db.close() or {}
		}
		app.create_tables()!
		app.migrate_tables()!
		shadow_id := app.find_or_create_github_shadow_user('ImportedOctocat')!
		app.db.exec("create trigger fail_shadow_email before insert on ${sql_table('Email')}
			when NEW.email = 'shadow-failure@example.com'
			begin select raise(abort, 'forced shadow email failure'); end")!

		mut failed := false
		app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             90_002
			username:       'ImportedOctocat'
			verified_email: 'shadow-failure@example.com'
		}) or { failed = true }
		assert failed
		shadow := app.get_user_by_id(shadow_id) or { panic('import shadow was removed') }
		assert shadow.github_id == 0
		assert !shadow.is_registered
		assert shadow.emails.len == 0
	} $else {
		assert true
	}
}

fn test_concurrent_github_callbacks_converge_on_one_complete_account() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_github_registration_race_${os.getpid()}')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := registration_atomicity_config(root)
		mut setup_app := registration_atomicity_app(conf)!
		setup_app.create_tables()!
		setup_app.migrate_tables()!
		setup_app.db.close()!

		start := chan bool{cap: 2}
		worker_a := spawn github_registration_race_worker(root, start)
		worker_b := spawn github_registration_race_worker(root, start)
		start <- true
		start <- true
		results := [worker_a.wait(), worker_b.wait()]
		assert results.all(it.err == '')
		assert results[0].user_id > 0
		assert results[0].user_id == results[1].user_id
		assert results.filter(it.newly_registered).len == 1

		mut verify_app := registration_atomicity_app(conf)!
		defer {
			verify_app.db.close() or {}
		}
		assert db_exec_values(mut verify_app.db,
			"select count(*) from ${sql_table('User')} where username = 'concurrentoctocat' and is_registered is true")! == [
			['1'],
		]
		assert db_exec_values(mut verify_app.db,
			"select count(*) from ${sql_table('Email')} where email = 'concurrent-oauth@example.com'")! == [
			['1'],
		]
		assert db_exec_values(mut verify_app.db,
			"select count(*) from ${sql_table('Activity')} where name = 'joined'")! == [
			['1'],
		]
	} $else {
		assert true
	}
}
