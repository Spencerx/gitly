module main

import x.json2 as json
import os
import git
import config
import net.urllib

struct CiTriggerPayload {
	repo_id      int
	commit_hash  string
	branch       string
	repo_path    string
	yaml_config  string
	callback_url string
}

struct CiTriggerResponse {
	success bool
	result  CiTriggerResult
}

struct CiTriggerResult {
	id     int
	status string
}

// trigger_ci_if_configured checks if the repo has a .gitly-ci.yml and triggers a CI run
fn (mut app App) trigger_ci_if_configured(repo_id int, branch_name string) {
	repo := app.find_repo_by_id(repo_id) or { return }

	if app.config.ci_service_url == '' {
		return
	}

	// Read .gitly-ci.yml from the repo using git show (works with bare repos)
	show_result := git.Git.exec_in_dir(repo.git_dir, ['show', '${branch_name}:.gitly-ci.yml'])
	if show_result.exit_code != 0 || show_result.output.trim_space() == '' {
		app.info('No .gitly-ci.yml found in ${repo.name}/${branch_name}')
		return
	}
	yaml_config := show_result.output

	app.info('Found .gitly-ci.yml in ${repo.name}/${branch_name}, triggering CI')
	app.send_ci_trigger(repo, branch_name, yaml_config)
}

// trigger_ci_with_config triggers CI with a known YAML config (e.g. when the file was just created via web UI)
fn (mut app App) trigger_ci_with_config(repo_id int, branch_name string, yaml_config string) {
	repo := app.find_repo_by_id(repo_id) or { return }

	if app.config.ci_service_url == '' {
		return
	}

	app.info('Triggering CI for ${repo.name}/${branch_name} with provided config')
	app.send_ci_trigger(repo, branch_name, yaml_config)
}

// Background jobs must not use the request App's database handle. Both the
// SQLite and PostgreSQL handles are unsafe to share with a spawned thread.
fn run_ci_trigger_if_configured(repo_id int, branch_name string, conf config.Config) {
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('CI trigger: cannot open ${db_backend_name()} database: ${err}')
			return
		}
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	app.trigger_ci_if_configured(repo_id, branch_name)
}

fn run_ci_trigger_with_config(repo_id int, branch_name string, yaml_config string, conf config.Config) {
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('CI trigger: cannot open ${db_backend_name()} database: ${err}')
			return
		}
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	app.trigger_ci_with_config(repo_id, branch_name, yaml_config)
}

fn ci_callback_url_for_config(conf config.Config) !string {
	configured := conf.ci_callback_url.trim_space()
	if configured != '' {
		return validate_ci_callback_url(configured)!
	}
	hostname := conf.hostname.trim_space().trim_right('/')
	if hostname == '' || hostname.contains_any('\x00\r\n') {
		return error('CI callback URL is not configured and hostname is empty or invalid')
	}
	scheme := if conf.cookie_secure { 'https' } else { 'http' }
	base := if hostname.starts_with('http://') || hostname.starts_with('https://') {
		hostname
	} else {
		'${scheme}://${hostname}'
	}
	return validate_ci_callback_url(base + '/api/v1/ci/status')!
}

fn validate_ci_callback_url(raw string) !string {
	if raw.contains_any('\x00\r\n') {
		return error('CI callback URL contains invalid characters')
	}
	parsed := urllib.parse(raw) or { return error('CI callback URL is invalid') }
	if parsed.scheme.to_lower() !in ['http', 'https'] || parsed.hostname() == ''
		|| parsed.raw_query != '' || parsed.fragment != '' {
		return error('CI callback URL must be an HTTP(S) URL without a query or fragment')
	}
	if user := parsed.user {
		if user.username != '' || user.password_set {
			return error('CI callback URL must not contain credentials')
		}
	}
	return raw
}

fn ci_run_id_from_trigger_response(status_code int, body string) !int {
	if status_code < 200 || status_code >= 300 {
		return error('CI trigger returned HTTP ${status_code}')
	}
	result := json.decode[CiTriggerResponse](body) or {
		return error('CI trigger returned invalid JSON')
	}
	if !result.success {
		return error('CI service rejected the trigger')
	}
	if result.result.id <= 0 {
		return error('CI trigger returned an invalid run id')
	}
	return result.result.id
}

fn (mut app App) send_ci_trigger(repo Repo, branch_name string, yaml_config string) {
	// Get the latest commit hash for this branch
	commit_hash := repo.get_last_branch_commit_hash(branch_name)
	if !is_full_commit_oid(commit_hash) || !is_safe_ref(branch_name) {
		app.warn('Refusing to trigger CI for an invalid branch or commit')
		return
	}

	callback_url := ci_callback_url_for_config(app.config) or {
		app.warn('Refusing to trigger CI: ${err}')
		return
	}

	// Get the absolute path to the git directory
	repo_path := os.real_path(repo.git_dir)

	payload := json.encode(CiTriggerPayload{
		repo_id:      repo.id
		commit_hash:  commit_hash
		branch:       branch_name
		repo_path:    repo_path
		yaml_config:  yaml_config
		callback_url: callback_url
	})

	// Record a distinct pending attempt before sending the request. The
	// reservation prevents concurrent replies from updating each other's run.
	reservation := app.begin_ci_status(repo.id, commit_hash, branch_name) or {
		app.warn('Failed to create CI status: ${err}')
		return
	}

	// Trigger CI service
	path := '/api/v1/trigger'
	app.info('Posting CI trigger to ${app.config.ci_service_url}${path}')

	response := app.ci_service_request(.post, path, payload) or {
		app.warn('Failed to trigger CI: ${err}')
		app.fail_ci_status_reservation(repo.id, commit_hash, branch_name, reservation) or {
			app.warn('Failed to mark CI trigger as failed: ${err}')
		}
		return
	}

	ci_run_id := ci_run_id_from_trigger_response(response.status_code, response.body) or {
		app.warn('Failed to trigger CI: ${err}')
		app.fail_ci_status_reservation(repo.id, commit_hash, branch_name, reservation) or {
			app.warn('Failed to mark CI trigger as failed: ${err}')
		}
		return
	}
	app.bind_ci_status_run(repo.id, commit_hash, branch_name, reservation, ci_run_id) or {
		app.warn('Failed to update CI status with run id: ${err}')
		return
	}
	app.info('CI run ${ci_run_id} triggered for ${repo.name}')
}
