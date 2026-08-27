module main

import config
import os

fn assert_github_owner_repo(url string, expected_owner string, expected_repo string) {
	owner, repo := parse_github_owner_repo(url) or {
		assert false
		return
	}
	assert owner == expected_owner
	assert repo == expected_repo
}

fn test_parse_github_owner_repo_accepts_common_clone_url_forms() {
	assert_github_owner_repo('https://github.com/vlang/gitly', 'vlang', 'gitly')
	assert_github_owner_repo('https://github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('http://github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('https://www.github.com/vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('git@github.com:vlang/gitly.git', 'vlang', 'gitly')
	assert_github_owner_repo('ssh://git@github.com/vlang/gitly.git', 'vlang', 'gitly')
}

fn test_parse_github_owner_repo_is_case_insensitive_for_protocol_and_host() {
	assert_github_owner_repo('HTTPS://GitHub.com/VLang/Gitly.git', 'VLang', 'Gitly')
	assert_github_owner_repo('https://WWW.GITHUB.COM/vlang/gitly.git', 'vlang', 'gitly')
}

fn test_parse_github_owner_repo_rejects_non_github_hosts() {
	assert !is_github_clone_url('https://example.com/vlang/gitly.git')
	assert !is_github_clone_url('https://github.com.evil.test/vlang/gitly.git')
	assert !is_github_clone_url('https://example.com/github.com/vlang/gitly.git')
}

fn test_local_registration_is_not_implicitly_linked_to_github_and_shadows_upgrade() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_github_auth_${os.getpid()}')
		db_path := os.join_path(root, 'test.sqlite')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := config.Config{
			repo_storage_path: root
			archive_path:      root
			avatars_path:      root
			sqlite:            config.SqliteConfig{
				path: db_path
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
		app.migrate_tables()!
		assert db_column_exists(mut app.db, 'User', 'github_id')!

		app.register_user('alice', 'local-password-hash', 'salt', [
			'alice@example.com',
		], false, false)!
		local := app.get_user_by_username('alice') or { panic('local user missing') }
		assert local.github_username == ''
		assert !local.is_github
		assert app.get_user_by_github_username('alice') == none
		legacy_mapping := 'alice'
		local_id := local.id
		sql app.db {
			update User set github_username = legacy_mapping where id == local_id
		}!
		app.clear_legacy_local_github_usernames()!
		migrated := app.get_user_by_username('alice') or { panic('local user missing') }
		assert migrated.github_username == ''
		mut collision_rejected := false
		app.find_or_create_github_shadow_user('alice') or { collision_rejected = true }
		assert collision_rejected

		shadow_id := app.find_or_create_github_shadow_user('OctoCat')!
		shadow_resolution := app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             10_001
			username:       'OctoCat'
			verified_email: 'octocat@example.com'
			avatar:         'https://avatars.githubusercontent.com/u/10001?v=4'
		})!
		assert shadow_resolution.newly_registered
		assert shadow_resolution.user.id == shadow_id
		assert shadow_resolution.user.github_id == 10_001
		assert shadow_resolution.user.is_github
		assert shadow_resolution.user.is_registered

		// The immutable id, not the mutable login, selects an existing account.
		// Provider metadata may follow a rename, but the local username and a
		// colliding local account must remain untouched.
		app.register_user('collision', 'local-password-hash', 'salt', [
			'collision@example.com',
		], false, false)!
		local_collision := app.get_user_by_username('collision') or {
			panic('collision user missing')
		}
		renamed_resolution := app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             10_001
			username:       'Collision'
			verified_email: 'new-octocat@example.com'
		})!
		assert !renamed_resolution.newly_registered
		assert renamed_resolution.user.id == shadow_id
		assert renamed_resolution.user.username == 'octocat'
		assert renamed_resolution.user.github_username == 'collision'
		assert (app.get_user_by_username('collision') or { panic('local collision missing') }).id == local_collision.id

		// A new GitHub owner of the old login can never authenticate as the old
		// local user after the provider login is reassigned.
		mut reassignment_rejected := false
		app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             20_002
			username:       'OctoCat'
			verified_email: 'attacker@example.com'
		}) or { reassignment_rejected = true }
		assert reassignment_rejected
		assert app.get_user_by_github_id(20_002) == none
		assert app.get_user_by_email('attacker@example.com') == none

		// Existing registered OAuth accounts have no numeric id until their first
		// post-migration login. A matching verified email safely binds them even
		// if their GitHub login was renamed; a username-only match is rejected.
		app.register_user('legacy', '', '', ['legacy@example.com'], true, false)!
		legacy_before := app.get_user_by_username('legacy') or { panic('legacy user missing') }
		assert legacy_before.github_id == 0
		legacy_resolution := app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             30_003
			username:       'RenamedLegacy'
			verified_email: 'legacy@example.com'
		})!
		assert !legacy_resolution.newly_registered
		assert legacy_resolution.user.id == legacy_before.id
		assert legacy_resolution.user.username == 'legacy'
		assert legacy_resolution.user.github_username == 'renamedlegacy'
		assert legacy_resolution.user.github_id == 30_003

		app.register_user('victim', '', '', ['victim@example.com'], true, false)!
		victim := app.get_user_by_username('victim') or { panic('victim missing') }
		mut legacy_takeover_rejected := false
		app.resolve_github_oauth_identity(GitHubOAuthIdentity{
			id:             40_004
			username:       'victim'
			verified_email: 'different@example.com'
		}) or { legacy_takeover_rejected = true }
		assert legacy_takeover_rejected
		assert (app.get_user_by_id(victim.id) or { panic('victim missing') }).github_id == 0

		// The database remains the final arbiter when two rows try to claim the
		// same provider identity.
		mut duplicate_id_rejected := false
		app.add_user(User{
			username:        'duplicate-id'
			github_username: 'duplicate-id'
			github_id:       10_001
			is_github:       true
		}) or { duplicate_id_rejected = true }
		assert duplicate_id_rejected
	} $else {
		assert true
	}
}

fn test_github_id_migration_adds_a_safe_legacy_column() {
	$if sqlite ? {
		root := os.join_path(os.temp_dir(), 'gitly_github_migration_${os.getpid()}')
		db_path := os.join_path(root, 'test.sqlite')
		os.mkdir_all(root)!
		defer {
			os.rmdir_all(root) or {}
		}
		conf := config.Config{
			repo_storage_path: root
			archive_path:      root
			avatars_path:      root
			sqlite:            config.SqliteConfig{
				path: db_path
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
		app.db.exec('drop table ${sql_table('User')}')!
		app.db.exec('create table ${sql_table('User')} (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			full_name TEXT NOT NULL DEFAULT \'\',
			username TEXT NOT NULL UNIQUE,
			github_username TEXT NOT NULL DEFAULT \'\',
			password TEXT NOT NULL DEFAULT \'\',
			salt TEXT NOT NULL DEFAULT \'\',
			created_at INTEGER NOT NULL DEFAULT 0,
			is_github INTEGER NOT NULL DEFAULT 0,
			is_registered INTEGER NOT NULL DEFAULT 0,
			is_blocked INTEGER NOT NULL DEFAULT 0,
			is_admin INTEGER NOT NULL DEFAULT 0,
			namechanges_count INTEGER NOT NULL DEFAULT 0,
			last_namechange_time INTEGER NOT NULL DEFAULT 0,
			posts_count INTEGER NOT NULL DEFAULT 0,
			last_post_time INTEGER NOT NULL DEFAULT 0,
			avatar TEXT NOT NULL DEFAULT \'\',
			login_attempts INTEGER NOT NULL DEFAULT 0,
			login_attempt_window_started_at BIGINT NOT NULL DEFAULT 0,
			login_throttled_until BIGINT NOT NULL DEFAULT 0,
			is_bootstrap_admin INTEGER NOT NULL DEFAULT 0
		)')!
		app.db.exec("insert into ${sql_table('User')} (username, github_username, is_github, is_registered) values ('legacy', 'Legacy', 1, 1)")!

		app.migrate_tables()!

		assert db_column_exists(mut app.db, 'User', 'github_id')!
		legacy := app.get_user_by_username('legacy') or { panic('migrated GitHub user missing') }
		assert legacy.github_id == 0
		assert legacy.github_username == 'legacy'
	} $else {
		assert true
	}
}
