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
		app.register_user('octocat', '', '', ['octocat@example.com'], true, false)!
		upgraded := app.get_user_by_github_username('octocat') or { panic('GitHub user missing') }
		assert upgraded.id == shadow_id
		assert upgraded.is_github
		assert upgraded.is_registered
	} $else {
		assert true
	}
}
