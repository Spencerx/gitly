module main

import time
import encoding.base64
import crypto.sha256
import os
import rand
import git

const ssh_authorized_keys_begin = '# BEGIN GITLY MANAGED KEYS'
const ssh_authorized_keys_end = '# END GITLY MANAGED KEYS'

struct SshKey {
	id           int @[primary; sql: serial]
	user_id      int
	title        string
	key          string
	fingerprint  string
	usage_type   string = 'auth'
	expires_at   int
	last_used_at int
	created_at   time.Time
}

struct DeployKey {
	id                 int @[primary; sql: serial]
	repo_id            int
	created_by         int
	title              string
	key                string
	fingerprint        string
	can_push           bool
	can_push_protected bool
	enabled            bool = true
	expires_at         int
	last_used_at       int
	created_at         int
}

struct SshCommandTarget {
	service   string
	owner     string
	repo_name string
}

fn ssh_key_parts(value string) ?(string, string) {
	parts := value.trim_space().fields()
	if parts.len < 2 {
		return none
	}
	algorithm := parts[0]
	if algorithm !in ['ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384',
		'ecdsa-sha2-nistp521', 'sk-ecdsa-sha2-nistp256@openssh.com', 'sk-ssh-ed25519@openssh.com'] {
		return none
	}
	encoded := parts[1]
	if encoded.len < 16 || encoded.len > 16_000 {
		return none
	}
	decoded := base64.decode(encoded)
	if decoded.len < 4 {
		return none
	}
	name_len := int((u32(decoded[0]) << 24) | (u32(decoded[1]) << 16) | (u32(decoded[2]) << 8) | u32(decoded[3]))
	if name_len <= 0 || name_len > 128 || decoded.len < 4 + name_len
		|| decoded[4..4 + name_len].bytestr() != algorithm {
		return none
	}
	return algorithm, encoded
}

fn is_valid_ssh_public_key(value string) bool {
	ssh_key_parts(value) or { return false }
	return true
}

fn ssh_key_fingerprint(value string) ?string {
	_, encoded := ssh_key_parts(value) or { return none }
	blob := base64.decode(encoded)
	if blob.len == 0 {
		return none
	}
	digest := sha256.sum(blob)
	return 'SHA256:' + base64.encode(digest[..]).trim_right('=')
}

fn normalized_ssh_public_key(value string) ?string {
	algorithm, encoded := ssh_key_parts(value) or { return none }
	return '${algorithm} ${encoded}'
}

fn valid_ssh_usage_type(value string) bool {
	return value in ['auth', 'signing', 'both']
}

fn (key SshKey) usable_for_auth(now int) bool {
	return key.usage_type in ['auth', 'both'] && (key.expires_at == 0 || key.expires_at > now)
}

fn (key DeployKey) usable_for_auth(now int) bool {
	return key.enabled && (key.expires_at == 0 || key.expires_at > now)
}

fn ssh_timestamp_description(value int) string {
	if value <= 0 {
		return 'Never'
	}
	return time.unix(value).relative()
}

fn (key SshKey) last_used_description() string {
	return ssh_timestamp_description(key.last_used_at)
}

fn (key SshKey) expiry_description() string {
	return if key.expires_at == 0 { 'Never' } else { time.unix(key.expires_at).format_ss() }
}

fn (key DeployKey) last_used_description() string {
	return ssh_timestamp_description(key.last_used_at)
}

fn (key DeployKey) expiry_description() string {
	return if key.expires_at == 0 { 'Never' } else { time.unix(key.expires_at).format_ss() }
}

fn (mut app App) ssh_fingerprint_exists(fingerprint string) bool {
	if fingerprint == '' {
		return true
	}
	user_count := sql app.db {
		select count from SshKey where fingerprint == fingerprint
	} or { 0 }
	if user_count > 0 {
		return true
	}
	deploy_count := sql app.db {
		select count from DeployKey where fingerprint == fingerprint
	} or { 0 }
	return deploy_count > 0
}

fn (mut app App) add_ssh_key(user_id int, title string, key string, usage_type string, expires_at int) ! {
	normalized := normalized_ssh_public_key(key) or { return error('Invalid SSH public key') }
	fingerprint := ssh_key_fingerprint(normalized) or { return error('Invalid SSH public key') }
	if user_id <= 0 || !valid_short_name(title) || !valid_ssh_usage_type(usage_type)
		|| expires_at < 0 || app.ssh_fingerprint_exists(fingerprint) {
		return error('SSH key is invalid or already in use')
	}
	new_ssh_key := SshKey{
		user_id:     user_id
		title:       title.trim_space()
		key:         normalized
		fingerprint: fingerprint
		usage_type:  usage_type
		expires_at:  expires_at
		created_at:  time.now()
	}
	sql app.db {
		insert new_ssh_key into SshKey
	}!
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
}

fn (mut app App) find_ssh_keys(user_id int) []SshKey {
	return sql app.db {
		select from SshKey where user_id == user_id order by created_at desc
	} or { []SshKey{} }
}

fn (app &App) find_ssh_key_by_id(id int) ?SshKey {
	rows := sql app.db {
		select from SshKey where id == id limit 1
	} or { []SshKey{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) remove_ssh_key(user_id int, id int) ! {
	sql app.db {
		delete from SshKey where id == id && user_id == user_id
	}!
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
}

fn (mut app App) add_deploy_key(repo_id int, created_by int, title string, key string, can_push bool,
	can_push_protected bool, expires_at int) ! {
	normalized := normalized_ssh_public_key(key) or { return error('Invalid SSH public key') }
	fingerprint := ssh_key_fingerprint(normalized) or { return error('Invalid SSH public key') }
	if repo_id <= 0 || created_by <= 0 || !valid_short_name(title) || expires_at < 0
		|| (can_push_protected && !can_push)
		|| app.ssh_fingerprint_exists(fingerprint) {
		return error('Deploy key is invalid or already in use')
	}
	row := DeployKey{
		repo_id:            repo_id
		created_by:         created_by
		title:              title.trim_space()
		key:                normalized
		fingerprint:        fingerprint
		can_push:           can_push
		can_push_protected: can_push_protected
		enabled:            true
		expires_at:         expires_at
		created_at:         int(time.now().unix())
	}
	sql app.db {
		insert row into DeployKey
	}!
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
}

fn (app &App) find_repo_deploy_keys(repo_id int) []DeployKey {
	return sql app.db {
		select from DeployKey where repo_id == repo_id order by created_at desc
	} or { []DeployKey{} }
}

fn (app &App) find_deploy_key_by_id(id int) ?DeployKey {
	rows := sql app.db {
		select from DeployKey where id == id limit 1
	} or { []DeployKey{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) remove_deploy_key(repo_id int, id int) ! {
	sql app.db {
		delete from DeployKey where id == id && repo_id == repo_id
	}!
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
}

fn (mut app App) delete_repo_deploy_keys(repo_id int) ! {
	sql app.db {
		delete from DeployKey where repo_id == repo_id
	}!
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
}

fn (mut app App) mark_ssh_key_used(kind string, id int) {
	now := int(time.now().unix())
	if kind == 'user' {
		sql app.db {
			update SshKey set last_used_at = now where id == id
		} or {}
	} else {
		sql app.db {
			update DeployKey set last_used_at = now where id == id
		} or {}
	}
}

fn authorized_keys_option_escape(value string) string {
	return value.replace('\\', '\\\\').replace('"', '\\"').replace('\r', '').replace('\n', '')
}

fn shell_single_quote(value string) string {
	return "'" + value.replace("'", '\'"\'"\'') + "'"
}

fn (app &App) ssh_forced_command(kind string, id int) string {
	command := '${shell_single_quote(os.executable())} ssh-shell ${shell_single_quote(kind)} ${id} ${shell_single_quote(os.real_path('config.json'))}'
	return 'restrict,command="${authorized_keys_option_escape(command)}"'
}

fn (mut app App) managed_authorized_key_lines() []string {
	now := int(time.now().unix())
	mut lines := []string{}
	keys := sql app.db {
		select from SshKey order by id
	} or { []SshKey{} }
	for key in keys {
		if key.usable_for_auth(now) && is_valid_ssh_public_key(key.key) {
			lines << '${app.ssh_forced_command('user', key.id)} ${key.key} gitly-user-${key.user_id}'
		}
	}
	keys2 := sql app.db {
		select from DeployKey order by id
	} or { []DeployKey{} }
	for key in keys2 {
		if key.usable_for_auth(now) && is_valid_ssh_public_key(key.key) {
			lines << '${app.ssh_forced_command('deploy', key.id)} ${key.key} gitly-deploy-${key.repo_id}'
		}
	}
	return lines
}

fn replace_managed_authorized_keys(existing string, managed []string) string {
	mut outside := []string{}
	mut inside := false
	for line in existing.split_into_lines() {
		if line == ssh_authorized_keys_begin {
			inside = true
			continue
		}
		if line == ssh_authorized_keys_end {
			inside = false
			continue
		}
		if !inside {
			outside << line
		}
	}
	for outside.len > 0 && outside.last().trim_space() == '' {
		outside.delete_last()
	}
	if outside.len > 0 {
		outside << ''
	}
	outside << ssh_authorized_keys_begin
	outside << managed
	outside << ssh_authorized_keys_end
	return outside.join('\n') + '\n'
}

fn (mut app App) sync_authorized_keys() ! {
	path := app.config.ssh_authorized_keys_path.trim_space()
	if !app.config.ssh_enabled || path == '' {
		return
	}
	parent := os.dir(path)
	os.mkdir_all(parent)!
	existing := os.read_file(path) or { '' }
	content := replace_managed_authorized_keys(existing, app.managed_authorized_key_lines())
	tmp := '${path}.gitly-${os.getpid()}-${rand.ulid()}'
	os.write_file(tmp, content)!
	os.chmod(tmp, 0o600)!
	os.mv(tmp, path, overwrite: true)!
}

fn (mut app App) backfill_ssh_key_fingerprints() ! {
	keys := sql app.db {
		select from SshKey where fingerprint == ''
	} or { []SshKey{} }
	for key in keys {
		fingerprint := ssh_key_fingerprint(key.key) or { continue }
		id := key.id
		sql app.db {
			update SshKey set fingerprint = fingerprint where id == id
		}!
	}
}

fn parse_ssh_original_command(command string) ?SshCommandTarget {
	clean := command.trim_space()
	space := clean.index(' ') or { return none }
	service := clean[..space]
	if service !in ['git-upload-pack', 'git-receive-pack'] {
		return none
	}
	mut path := clean[space + 1..].trim_space()
	if path.len < 3 || path[0] !in [`'`, `"`] || path[path.len - 1] != path[0] {
		return none
	}
	path = path[1..path.len - 1]
	if path.starts_with('/') || path.contains_any('\x00\r\n\\') || path.contains('..') {
		return none
	}
	path = path.trim_string_right('.git')
	parts := path.split('/')
	if parts.len != 2 || parts[0] == '' || parts[1] == '' {
		return none
	}
	return SshCommandTarget{
		service:   service
		owner:     parts[0]
		repo_name: parts[1]
	}
}

fn run_git_service(repo Repo, target SshCommandTarget, environment map[string]string) int {
	git_path := git.get_git_executable_path() or { 'git' }
	mut process := os.new_process(git_path)
	process.set_args([target.service.after('git-'), repo.git_dir])
	if environment.len > 0 {
		mut merged := os.environ()
		for key, value in environment {
			merged[key] = value
		}
		process.set_environment(merged)
	}
	process.run()
	process.wait()
	code := process.code
	process.close()
	return code
}
