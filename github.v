// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import x.json2 as json
import net.http
import time
import git
import validation
import crypto.hmac
import orm
// import veb.auth as oauth
import veb.oauth

struct GitHubUser {
	id       i64
	username string @[json: 'login']
	name     string
	email    string
	avatar   string @[json: 'avatar_url']
}

struct GitHubAccessToken {
	access_token      string
	error             string
	error_description string
}

struct GitHubEmail {
	email    string
	primary  bool
	verified bool
}

struct GitHubIssueAuthor {
	id    i64
	login string
}

struct GitHubPullRequestRef {
	url string
}

struct GitHubPullRequestBranch {
	ref_name string @[json: 'ref']
	sha      string
}

struct GitHubLabel {
	name        string
	color       string
	description string
}

struct GitHubRepoInfo {
	description string
}

struct GitHubContributor {
	login      string
	avatar_url string
	type_      string @[json: 'type']
	html_url   string
	id         i64
}

struct GitHubIssue {
	number       int
	title        string
	body         string
	state        string
	created_at   string
	user         GitHubIssueAuthor
	pull_request GitHubPullRequestRef
	labels       []GitHubLabel
}

struct GitHubPullRequest {
	number     int
	title      string
	body       string
	state      string
	created_at string
	user       GitHubIssueAuthor
	head       GitHubPullRequestBranch
	base       GitHubPullRequestBranch
}

fn parse_github_timestamp(s string) int {
	if s == '' {
		return int(time.now().unix())
	}
	t := time.parse_iso8601(s) or { return int(time.now().unix()) }
	return int(t.unix())
}

fn parse_github_owner_repo(clone_url string) ?(string, string) {
	mut s := clone_url.trim_space()
	mut lower := s.to_lower()
	if lower.starts_with('ssh://') {
		s = s['ssh://'.len..]
		lower = s.to_lower()
	}
	for prefix in ['https://', 'http://', 'git@'] {
		if lower.starts_with(prefix) {
			s = s[prefix.len..]
			lower = s.to_lower()
			break
		}
	}
	if lower.starts_with('git@') {
		s = s['git@'.len..]
		lower = s.to_lower()
	}
	if lower.starts_with('www.') {
		s = s['www.'.len..]
		lower = s.to_lower()
	}
	if !lower.starts_with('github.com') {
		return none
	}
	s = s['github.com'.len..]
	if s == '' || !(s[0] == `/` || s[0] == `:`) {
		return none
	}
	s = s.trim_left(':/')
	if idx := s.index('?') {
		s = s[..idx]
	}
	if idx := s.index('#') {
		s = s[..idx]
	}
	s = s.trim('/')
	if s.ends_with('.git') {
		s = s[..s.len - '.git'.len]
	}
	parts := s.split('/')
	if parts.len < 2 || parts[0] == '' || parts[1] == '' {
		return none
	}
	return parts[0], parts[1]
}

fn is_github_clone_url(clone_url string) bool {
	parse_github_owner_repo(clone_url) or { return false }
	return true
}

// Returns the local user id for a GitHub login, creating an unregistered
// "shadow" user (no password, no email, just the username and GitHub avatar)
// when one does not yet exist. Callers without GitHub's immutable numeric id
// use zero; OAuth safely binds such a shadow when the real user first signs in.
fn (mut app App) find_or_create_github_shadow_user(github_login string) !int {
	return app.find_or_create_github_shadow_identity(github_login, 0, '')
}

fn (mut app App) find_or_create_github_shadow_identity(github_login string, github_id i64, avatar_url string) !int {
	login := github_login.trim_space().to_lower()
	if !validation.is_username_valid(login) || is_reserved_account_name(login) {
		return error('invalid GitHub username')
	}
	if github_id < 0 {
		return error('invalid GitHub user id')
	}
	if github_id > 0 {
		if existing := app.get_user_by_github_id(github_id) {
			if !existing.is_github {
				return error('GitHub id is linked to an invalid local account')
			}
			app.update_github_identity_metadata(existing.id, login, avatar_url)!
			return existing.id
		}
	}
	if u := app.get_user_by_username(login) {
		if u.is_github && (github_id == 0 || u.github_id == github_id) {
			return u.id
		}
		if u.is_github && github_id > 0 && u.github_id == 0 && !u.is_registered {
			app.bind_github_identity(u.id, github_id, login)!
			app.update_github_identity_metadata(u.id, login, avatar_url)!
			return u.id
		}
		return error('GitHub username collides with an unlinked local account')
	}
	avatar := if avatar_url.starts_with('https://avatars.githubusercontent.com/') {
		avatar_url
	} else {
		'https://github.com/${login}.png'
	}
	user := User{
		username:        login
		github_username: login
		github_id:       github_id
		is_github:       true
		is_registered:   false
		avatar:          avatar
		created_at:      time.now()
	}
	app.add_user(user) or {
		if github_id > 0 {
			if existing := app.get_user_by_github_id(github_id) {
				return existing.id
			}
		}
		return err
	}
	created := app.get_user_by_username(login) or {
		return error('shadow user not found after insert: ${login}')
	}
	return created.id
}

// fetch_github_repo_description returns the GitHub description for a repo, or
// an empty string if it cannot be retrieved.
fn fetch_github_repo_description(clone_url string) string {
	owner, name := parse_github_owner_repo(clone_url) or {
		eprintln('[github-info] cannot parse github url: ${clone_url}')
		return ''
	}
	url := 'https://api.github.com/repos/${owner}/${name}'
	eprintln('[github-info] GET ${url}')
	mut req := http.new_request(.get, url, '')
	req.add_header(.user_agent, 'gitly')
	req.add_header(.accept, 'application/vnd.github+json')
	resp := req.do() or {
		eprintln('[github-info] request failed: ${err}')
		return ''
	}
	if resp.status_code != 200 {
		eprintln('[github-info] non-200 status ${resp.status_code}: ${resp.body#[..200]}')
		return ''
	}
	info := json.decode[GitHubRepoInfo](resp.body) or {
		eprintln('[github-info] cannot decode response: ${err}')
		return ''
	}
	return info.description
}

fn (mut app App) import_github_contributors(repo_id int, clone_url string) ! {
	eprintln('[github-contrib] starting for repo_id=${repo_id} clone_url=${clone_url}')
	owner, name := parse_github_owner_repo(clone_url) or {
		return error('cannot parse github url: ${clone_url}')
	}
	mut page := 1
	mut total := 0
	for page <= 10 {
		url := 'https://api.github.com/repos/${owner}/${name}/contributors?per_page=100&page=${page}'
		eprintln('[github-contrib] GET ${url}')
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'gitly')
		req.add_header(.accept, 'application/vnd.github+json')
		resp := req.do() or { return error('github api request failed: ${err}') }
		if resp.status_code != 200 {
			return error('github api ${resp.status_code}: ${resp.body}')
		}
		contributors := json.decode[[]GitHubContributor](resp.body) or {
			return error('cannot decode github contributors: ${err}')
		}
		if contributors.len == 0 {
			break
		}
		for c in contributors {
			if c.login == '' || c.type_ == 'Bot' {
				continue
			}
			user_id := app.find_or_create_github_shadow_identity(c.login, c.id, c.avatar_url) or {
				eprintln('[github-contrib] cannot resolve @${c.login}: ${err}')
				continue
			}
			app.add_contributor(user_id, repo_id) or {
				eprintln('[github-contrib] cannot link @${c.login}: ${err}')
				continue
			}
			total++
		}
		if contributors.len < 100 {
			break
		}
		page++
	}
	app.update_repo_contributor_count(repo_id) or {
		eprintln('[github-contrib] cannot update contributor count: ${err}')
	}
	eprintln('[github-contrib] done: imported ${total} contributors into repo ${repo_id}')
}

fn (mut app App) import_github_pull_requests(repo Repo, owner_user_id int) ! {
	eprintln('[github-pr] starting for repo_id=${repo.id} clone_url=${repo.clone_url} owner_user_id=${owner_user_id}')
	owner, name := parse_github_owner_repo(repo.clone_url) or {
		return error('cannot parse github url: ${repo.clone_url}')
	}
	defer {
		app.sync_repo_open_pr_count(repo.id) or {
			eprintln('[github-pr] cannot sync open PR count: ${err}')
		}
	}
	mut page := 1
	mut imported := 0
	mut fetched := 0
	for page <= 100 {
		url := 'https://api.github.com/repos/${owner}/${name}/pulls?state=open&per_page=100&page=${page}'
		eprintln('[github-pr] GET ${url}')
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'gitly')
		req.add_header(.accept, 'application/vnd.github+json')
		resp := req.do() or {
			eprintln('[github-pr] ERROR: request failed: ${err}')
			return error('github api request failed: ${err}')
		}
		eprintln('[github-pr] page=${page} status=${resp.status_code} body_len=${resp.body.len}')
		if resp.status_code != 200 {
			eprintln('[github-pr] ERROR body: ${resp.body}')
			return error('github api ${resp.status_code}: ${resp.body}')
		}
		prs := json.decode[[]GitHubPullRequest](resp.body) or {
			eprintln('[github-pr] ERROR: cannot decode response: ${err}')
			eprintln('[github-pr] response body was: ${resp.body#[..1000]}')
			return error('cannot decode github pull requests: ${err}')
		}
		eprintln('[github-pr] decoded ${prs.len} pull requests on page ${page}')
		if prs.len == 0 {
			break
		}
		for gh_pr in prs {
			if gh_pr.number <= 0 {
				continue
			}
			head_branch := 'pr/${gh_pr.number}'
			refspec := '+refs/pull/${gh_pr.number}/head:refs/heads/${head_branch}'
			fetch_result := git.Git.fetch_ref(repo.git_dir, 'origin', refspec)
			if fetch_result.exit_code != 0 {
				eprintln('[github-pr] cannot fetch PR #${gh_pr.number}: ${fetch_result.output}')
				continue
			}
			fetched++

			base_branch := gh_pr.base.ref_name
			if base_branch == '' || !is_safe_ref(base_branch) {
				eprintln('[github-pr] skipping PR #${gh_pr.number}: invalid base branch "${base_branch}"')
				continue
			}
			if app.pull_request_exists_for_head(repo.id, head_branch) {
				continue
			}
			mut author_id := owner_user_id
			if gh_pr.user.login != '' {
				author_id = app.find_or_create_github_shadow_identity(gh_pr.user.login,
					gh_pr.user.id, '') or {
					eprintln('[github-pr] cannot resolve author @${gh_pr.user.login}: ${err}')
					owner_user_id
				}
			}
			created_at := parse_github_timestamp(gh_pr.created_at)
			title := if gh_pr.title != '' { gh_pr.title } else { 'Pull request #${gh_pr.number}' }
			app.add_imported_pull_request(repo.id, author_id, title, gh_pr.body, head_branch,
				base_branch, created_at) or {
				eprintln('[github-pr] ERROR inserting PR #${gh_pr.number}: ${err}')
				continue
			}
			app.increment_repo_open_prs(repo.id) or {
				eprintln('[github-pr] cannot bump PR count: ${err}')
			}
			imported++
		}
		if prs.len < 100 {
			break
		}
		page++
	}
	eprintln('[github-pr] done: fetched ${fetched} PR refs, imported ${imported} pull requests into repo ${repo.id}')
}

fn (mut app App) import_github_issues(repo_id int, clone_url string, owner_user_id int) ! {
	eprintln('[github-import] starting for repo_id=${repo_id} clone_url=${clone_url} owner_user_id=${owner_user_id}')
	defer {
		app.sync_repo_open_issue_count(repo_id) or {
			eprintln('[github-import] cannot sync issue count: ${err}')
		}
	}
	owner, name := parse_github_owner_repo(clone_url) or {
		eprintln('[github-import] ERROR: cannot parse github url: ${clone_url}')
		return error('cannot parse github url: ${clone_url}')
	}
	eprintln('[github-import] parsed owner=${owner} name=${name}')
	mut page := 1
	mut total := 0
	for page <= 100 {
		url := 'https://api.github.com/repos/${owner}/${name}/issues?state=open&per_page=100&page=${page}'
		eprintln('[github-import] GET ${url}')
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'gitly')
		req.add_header(.accept, 'application/vnd.github+json')
		resp := req.do() or {
			eprintln('[github-import] ERROR: request failed: ${err}')
			return error('github api request failed: ${err}')
		}
		eprintln('[github-import] page=${page} status=${resp.status_code} body_len=${resp.body.len}')
		if resp.status_code != 200 {
			eprintln('[github-import] ERROR body: ${resp.body}')
			return error('github api ${resp.status_code}: ${resp.body}')
		}
		issues := json.decode[[]GitHubIssue](resp.body) or {
			eprintln('[github-import] ERROR: cannot decode response: ${err}')
			eprintln('[github-import] response body was: ${resp.body#[..1000]}')
			return error('cannot decode github issues: ${err}')
		}
		eprintln('[github-import] decoded ${issues.len} issues on page ${page}')
		if issues.len == 0 {
			break
		}
		for gi in issues {
			// GitHub returns PRs in the issues endpoint; skip them.
			if gi.pull_request.url != '' {
				eprintln('[github-import] skipping PR #${gi.number}')
				continue
			}
			mut author_id := owner_user_id
			if gi.user.login != '' {
				author_id = app.find_or_create_github_shadow_identity(gi.user.login, gi.user.id, '') or {
					eprintln('[github-import] cannot resolve author @${gi.user.login}: ${err}')
					owner_user_id
				}
			}
			created_at := parse_github_timestamp(gi.created_at)
			issue_id := app.add_imported_issue_returning_id(repo_id, author_id, gi.title, gi.body,
				created_at) or {
				eprintln('[github-import] ERROR inserting issue #${gi.number}: ${err}')
				continue
			}
			app.increment_repo_issues(repo_id) or {
				eprintln('[github-import] cannot bump issue count: ${err}')
			}
			for gl in gi.labels {
				if gl.name == '' {
					continue
				}
				color := if gl.color == '' { 'cccccc' } else { gl.color }
				label_id := app.find_or_create_label(repo_id, gl.name, color) or {
					eprintln('[github-import] cannot create label ${gl.name}: ${err}')
					continue
				}
				if label_id == 0 {
					continue
				}
				app.add_issue_label(issue_id, label_id) or {
					eprintln('[github-import] cannot link label ${gl.name} to issue #${gi.number}: ${err}')
				}
			}
			total++
		}
		if issues.len < 100 {
			break
		}
		page++
	}
	eprintln('[github-import] done: imported ${total} issues into repo ${repo_id}')
}

fn configured_github_request(method http.Method, url string, body string) http.Request {
	mut req := http.new_request(method, url, body)
	req.read_timeout = 10 * time.second
	req.write_timeout = 10 * time.second
	req.allow_redirect = false
	req.max_retries = 1
	req.stop_receiving_limit = 1024 * 1024
	req.add_header(.user_agent, 'gitly')
	return req
}

fn (mut app App) exchange_github_oauth_code(code string, state string) !string {
	payload := json.encode(oauth.Request{
		client_id:     app.settings.oauth_client_id
		client_secret: app.settings.oauth_client_secret
		code:          code
		state:         state
	})
	mut req := configured_github_request(.post, 'https://github.com/login/oauth/access_token',
		payload)
	req.add_header(.content_type, 'application/json')
	req.add_header(.accept, 'application/json')
	resp := req.do()!
	if resp.status_code != 200 {
		return error('GitHub token exchange returned ${resp.status_code}')
	}
	result := json.decode[GitHubAccessToken](resp.body)!
	if result.access_token == '' || result.access_token.len > 512 {
		return error(if result.error_description != '' {
			result.error_description
		} else {
			'GitHub did not return an access token'
		})
	}
	return result.access_token
}

fn github_api_get(path string, token string) !http.Response {
	mut req := configured_github_request(.get, 'https://api.github.com${path}', '')
	req.add_header(.authorization, 'Bearer ${token}')
	req.add_header(.accept, 'application/vnd.github+json')
	resp := req.do()!
	if resp.status_code != 200 {
		return error('GitHub API returned ${resp.status_code}')
	}
	return resp
}

fn github_primary_email(token string) !string {
	resp := github_api_get('/user/emails', token)!
	emails := json.decode[[]GitHubEmail](resp.body)!
	for item in emails {
		if item.primary && item.verified && validation.is_email_valid(item.email) {
			return item.email.trim_space().to_lower()
		}
	}
	for item in emails {
		if item.verified && validation.is_email_valid(item.email) {
			return item.email.trim_space().to_lower()
		}
	}
	return error('GitHub account has no verified email address')
}

struct GitHubOAuthIdentity {
	id             i64
	username       string
	verified_email string
	avatar         string
}

struct GitHubOAuthResolution {
	user             User
	newly_registered bool
}

struct GitHubRegistrationTxResult {
	user             User
	newly_registered bool
}

// bind_github_identity upgrades a legacy GitHub row from mutable-login lookup
// to GitHub's immutable numeric id. The conditional update and partial unique
// index make concurrent first logins safe on both SQLite and PostgreSQL.
fn (mut app App) bind_github_identity(user_id int, github_id i64, github_username string) ! {
	if user_id <= 0 || github_id <= 0 {
		return error('invalid GitHub identity')
	}
	current := app.get_user_by_id(user_id) or { return error('local user not found') }
	if !current.is_github {
		return error('local account is not linked to GitHub')
	}
	if current.github_id == github_id {
		return
	}
	if current.github_id != 0 {
		return error('local account is linked to a different GitHub identity')
	}
	rows := db_exec_values(mut app.db, 'update ${sql_table('User')} set
		${sql_table('github_id')} = ${github_id},
		${sql_table('github_username')} = ${sql_literal(github_username)}
		where ${sql_table('id')} = ${user_id}
			and ${sql_table('is_github')} is true
			and ${sql_table('github_id')} = 0
		returning ${sql_table('id')}') or {
		if is_unique_constraint_error(err) {
			return error('GitHub identity is already linked to another account')
		}
		return err
	}
	if rows.len == 1 {
		return
	}
	refreshed := app.get_user_by_id(user_id) or { return error('local user not found') }
	if refreshed.github_id != github_id {
		return error('GitHub identity changed during login')
	}
}

// GitHub logins can be renamed and later reassigned. Keep the current login as
// provider metadata, but never rename Gitly's local username here: that could
// take over a local namespace or move repositories behind an OAuth callback.
fn (mut app App) update_github_identity_metadata(user_id int, github_username string, avatar_url string) ! {
	login := github_username.trim_space().to_lower()
	if !validation.is_username_valid(login) || is_reserved_account_name(login) {
		return error('invalid GitHub username')
	}
	id := user_id
	if avatar_url.starts_with('https://avatars.githubusercontent.com/') {
		avatar := avatar_url
		sql app.db {
			update User set github_username = login, avatar = avatar where id == id
			&& is_github == true
		}!
	} else {
		sql app.db {
			update User set github_username = login where id == id && is_github == true
		}!
	}
}

// finish_github_registration_tx binds an immutable provider id, records the
// verified email, and activates the account as one database unit. The harmless
// UPDATE lock serializes callbacks for one shadow before their state is
// inspected on both SQLite and PostgreSQL.
fn finish_github_registration_tx(mut tx orm.Tx, user_id int, identity GitHubOAuthIdentity) !GitHubRegistrationTxResult {
	if user_id <= 0 || identity.id <= 0 {
		return error('invalid GitHub identity')
	}
	locked := tx.execute('update ${sql_table('User')} set ${sql_table('id')} = ${sql_table('id')}
		where ${sql_table('id')} = ${user_id} returning ${sql_table('id')}')!
	if locked.len != 1 {
		return error('local user not found')
	}
	id := user_id
	current_rows := sql tx {
		select from User where id == id limit 1
	}!
	if current_rows.len != 1 {
		return error('local user not found')
	}
	current := current_rows[0]
	if !current.is_github {
		return error('local account is not linked to GitHub')
	}
	if current.github_id != 0 && current.github_id != identity.id {
		return error('local account is linked to a different GitHub identity')
	}

	verified_email := identity.verified_email
	email_rows := sql tx {
		select from Email where email == verified_email limit 1
	}!
	if email_rows.len == 1 && email_rows[0].user_id != id {
		return error('verified GitHub email is already used by another account')
	}
	// Registered legacy accounts are eligible for their first immutable-id bind
	// only because resolution already matched this provider-verified address.
	// Recheck that proof under the same lock instead of adding a new address.
	if current.is_registered && email_rows.len != 1 {
		return error('legacy GitHub account email did not match')
	}

	provider_id := identity.id
	provider_login := identity.username
	zero_id := i64(0)
	if identity.avatar.starts_with('https://avatars.githubusercontent.com/') {
		provider_avatar := identity.avatar
		sql tx {
			update User set github_id = provider_id, github_username = provider_login, avatar = provider_avatar,
			is_registered = true where id == id && is_github == true
			&& (github_id == zero_id || github_id == provider_id)
		} or {
			if is_unique_constraint_error(err) {
				return error('GitHub identity is already linked to another account')
			}
			return err
		}
	} else {
		sql tx {
			update User set github_id = provider_id, github_username = provider_login, is_registered = true
			where id == id && is_github == true
			&& (github_id == zero_id || github_id == provider_id)
		} or {
			if is_unique_constraint_error(err) {
				return error('GitHub identity is already linked to another account')
			}
			return err
		}
	}

	bound_rows := sql tx {
		select from User where id == id limit 1
	}!
	if bound_rows.len != 1 || bound_rows[0].github_id != provider_id || !bound_rows[0].is_github
		|| !bound_rows[0].is_registered {
		return error('GitHub account binding did not complete')
	}

	newly_registered := !current.is_registered
	if email_rows.len == 0 {
		user_email := Email{
			user_id: id
			email:   verified_email
		}
		sql tx {
			insert user_email into Email
		} or {
			if is_unique_constraint_error(err) {
				return error('verified GitHub email is already used by another account')
			}
			return err
		}
	}
	mut resolved := bound_rows[0]
	resolved.emails = sql tx {
		select from Email where user_id == id
	}!
	return GitHubRegistrationTxResult{
		user:             resolved
		newly_registered: newly_registered
	}
}

fn (mut app App) github_registration_after_commit(result GitHubRegistrationTxResult) GitHubOAuthResolution {
	if result.newly_registered {
		app.add_activity(result.user.id, 'joined') or {
			app.info('could not record GitHub joined activity: ${err}')
		}
		app.create_user_dir(result.user.username)
		// Bootstrap is intentionally a separate, post-commit claim: an account
		// that rolls back can never reserve the one-time administrator marker.
		app.claim_bootstrap_administrator(result.user.id) or {
			app.warn('Could not claim bootstrap administrator for GitHub user ${result.user.id}: ${err}')
		}
	}
	return GitHubOAuthResolution{
		user:             result.user
		newly_registered: result.newly_registered
	}
}

fn (mut app App) finish_github_registration(user User, identity GitHubOAuthIdentity) !GitHubOAuthResolution {
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	result := finish_github_registration_tx(mut tx, user.id, identity)!
	tx.commit()!
	committed = true
	return app.github_registration_after_commit(result)
}

fn (mut app App) register_new_github_identity(identity GitHubOAuthIdentity) !GitHubOAuthResolution {
	mut tx := db_begin_transaction(mut app.db)!
	mut closed := false
	defer {
		if !closed {
			tx.rollback() or {}
		}
	}
	login := identity.username
	shadow := User{
		username:        login
		github_username: login
		github_id:       identity.id
		is_github:       true
		is_registered:   false
		avatar:          if identity.avatar.starts_with('https://avatars.githubusercontent.com/') {
			identity.avatar
		} else {
			default_avatar_name
		}
		created_at:      time.now()
	}
	sql tx {
		insert shadow into User
	} or {
		insert_err := err
		tx.rollback() or {}
		closed = true
		// A concurrent callback may have completed the same identity while this
		// INSERT waited on the unique provider-id or username constraint.
		if is_unique_constraint_error(insert_err) {
			if concurrent := app.get_user_by_github_id(identity.id) {
				return app.finish_github_registration(concurrent, identity)
			}
			if concurrent := app.get_user_by_username(login) {
				return app.finish_github_registration(concurrent, identity)
			}
		}
		return insert_err
	}
	orgs := sql tx {
		select from Org where name == login limit 1
	}!
	if orgs.len > 0 {
		return error('GitHub username collides with an existing organization')
	}
	created_rows := sql tx {
		select from User where github_id == identity.id && username == login limit 1
	}!
	if created_rows.len != 1 {
		return error('GitHub shadow was not found after insert')
	}
	result := finish_github_registration_tx(mut tx, created_rows[0].id, identity)!
	tx.commit()!
	closed = true
	return app.github_registration_after_commit(result)
}

// resolve_github_oauth_identity authenticates by immutable numeric id. A
// pre-migration registered GitHub account may be bound only when GitHub proves
// ownership of an email already stored on that account. Unregistered import
// shadows are safe to upgrade because they have never been login-capable.
fn (mut app App) resolve_github_oauth_identity(raw GitHubOAuthIdentity) !GitHubOAuthResolution {
	identity := GitHubOAuthIdentity{
		id:             raw.id
		username:       raw.username.trim_space().to_lower()
		verified_email: raw.verified_email.trim_space().to_lower()
		avatar:         raw.avatar
	}
	if identity.id <= 0 {
		return error('GitHub did not return a valid immutable user id')
	}
	if !validation.is_username_valid(identity.username)
		|| is_reserved_account_name(identity.username) {
		return error('GitHub returned an invalid username')
	}
	if !validation.is_email_valid(identity.verified_email) {
		return error('GitHub did not return a verified email')
	}

	if bound := app.get_user_by_github_id(identity.id) {
		if !bound.is_github {
			return error('GitHub identity is linked to an invalid local account')
		}
		if !bound.is_registered {
			return app.finish_github_registration(bound, identity)
		}
		app.update_github_identity_metadata(bound.id, identity.username, identity.avatar)!
		resolved := app.get_user_by_id(bound.id) or { return error('GitHub user not found') }
		return GitHubOAuthResolution{
			user: resolved
		}
	}

	// This is the only compatibility path for a registered pre-migration OAuth
	// account, and it requires a verified email match before the first id bind.
	if email_user := app.get_user_by_email(identity.verified_email) {
		if email_user.is_github && email_user.github_id == 0 {
			return app.finish_github_registration(email_user, identity)
		}
		return error('verified GitHub email is already used by another account')
	}

	if login_user := app.get_user_by_github_username(identity.username) {
		if !login_user.is_github {
			return error('GitHub username collides with an unlinked local account')
		}
		if login_user.github_id != 0 {
			return error('GitHub username belongs to a different immutable identity')
		}
		if login_user.is_registered {
			return error('legacy GitHub account email did not match')
		}
		return app.finish_github_registration(login_user, identity)
	}

	if username_user := app.get_user_by_username(identity.username) {
		if username_user.is_github && !username_user.is_registered && username_user.github_id == 0 {
			return app.finish_github_registration(username_user, identity)
		}
		return error('GitHub username collides with an existing local account')
	}
	if _ := app.get_org_by_name(identity.username) {
		return error('GitHub username collides with an existing organization')
	}

	return app.register_new_github_identity(identity)
}

@['/oauth']
pub fn (mut app App) handle_oauth() veb.Result {
	code := ctx.query['code']
	state := ctx.query['state']
	if code == '' || code.len > 1024 || state.len > 256 {
		app.add_security_log(user_id: ctx.user.id, kind: .empty_oauth_code) or {
			app.info(err.str())
		}
		return ctx.redirect_to_login()
	}

	csrf := ctx.get_cookie('csrf') or { return ctx.redirect_to_login() }
	if csrf == '' || !hmac.equal(csrf.bytes(), state.bytes()) {
		app.add_security_log(
			user_id: ctx.user.id
			kind:    .wrong_oauth_state
			arg1:    'OAuth state did not match the browser session'
		) or { app.info(err.str()) }
		return ctx.redirect_to_login()
	}
	// Make state single-use before contacting GitHub. A failed exchange starts a
	// fresh login instead of leaving a replayable state cookie behind.
	ctx.set_cookie(
		name:      'csrf'
		value:     ''
		path:      '/'
		max_age:   -1
		http_only: true
		same_site: .same_site_lax_mode
		secure:    app.config.cookie_secure
	)

	token := app.exchange_github_oauth_code(code, csrf) or {
		app.warn('GitHub OAuth token exchange failed: ${err}')
		return ctx.redirect_to_login()
	}
	user_response := github_api_get('/user', token) or {
		app.warn('GitHub OAuth user lookup failed: ${err}')
		return ctx.redirect_to_login()
	}
	github_user := json.decode[GitHubUser](user_response.body) or { return ctx.redirect_to_login() }
	email := github_primary_email(token) or {
		app.add_security_log(
			user_id: ctx.user.id
			kind:    .empty_oauth_email
			arg1:    'GitHub account did not provide a verified email'
		) or { app.info(err.str()) }
		return ctx.redirect_to_login()
	}
	resolution := app.resolve_github_oauth_identity(GitHubOAuthIdentity{
		id:             github_user.id
		username:       github_user.username
		verified_email: email
		avatar:         github_user.avatar
	}) or {
		app.warn('GitHub OAuth identity resolution failed: ${err}')
		return ctx.redirect_to_login()
	}
	user := resolution.user
	if resolution.newly_registered {
		app.add_security_log(
			user_id: user.id
			kind:    .registered_via_github
			arg1:    github_user.username
		) or { app.info(err.str()) }
	}
	if user.is_blocked || !user.is_registered || !user.is_github {
		return ctx.redirect_to_login()
	}

	app.auth_user(mut ctx, user, ctx.ip()) or {
		app.warn('GitHub OAuth session creation failed for user ${user.id}: ${err}')
		return ctx.redirect_to_login()
	}
	app.add_security_log(user_id: user.id, kind: .logged_in_via_github, arg1: github_user.username) or {
		app.info(err.str())
	}
	return ctx.redirect('/${user.username}')
}
