module main

import time
import crypto.rand

enum CiStatusEnum {
	pending   = 0
	running   = 1
	success   = 2
	failure   = 3
	cancelled = 4
	timed_out = 5
}

fn (s CiStatusEnum) str() string {
	return match s {
		.pending { 'pending' }
		.running { 'running' }
		.success { 'success' }
		.failure { 'failure' }
		.cancelled { 'cancelled' }
		.timed_out { 'timed_out' }
	}
}

fn (s CiStatusEnum) css_class() string {
	return match s {
		.pending { 'ci-pending' }
		.running { 'ci-running' }
		.success { 'ci-success' }
		.failure { 'ci-failure' }
		.cancelled { 'ci-cancelled' }
		.timed_out { 'ci-failure' }
	}
}

fn (s CiStatusEnum) icon() string {
	return match s {
		.pending { '⏳' }
		.running { '🔄' }
		.success { '✓' }
		.failure { '✗' }
		.cancelled { '⊘' }
		.timed_out { '⌛' }
	}
}

struct CiStatus {
	id          int @[primary; sql: serial]
	repo_id     int
	commit_hash string
	branch      string
	status      CiStatusEnum
	ci_run_id   int
	created_at  int
	updated_at  int
}

// Git can use SHA-1 or SHA-256 object formats. CI identities must use the full,
// canonical object id so an abbreviated id can never collide with or fail to
// match a callback carrying the complete id.
fn is_full_commit_oid(hash string) bool {
	if hash.len !in [40, 64] {
		return false
	}
	for ch in hash {
		if !((ch >= `0` && ch <= `9`) || (ch >= `a` && ch <= `f`)) {
			return false
		}
	}
	return true
}

fn ci_status_from_string(s string) CiStatusEnum {
	return match s {
		'pending' { CiStatusEnum.pending }
		'running' { CiStatusEnum.running }
		'success' { CiStatusEnum.success }
		'failure' { CiStatusEnum.failure }
		'cancelled' { CiStatusEnum.cancelled }
		'timed_out' { CiStatusEnum.timed_out }
		else { CiStatusEnum.pending }
	}
}

fn (mut app App) find_ci_status_for_commit(repo_id int, commit_hash string, branch string) ?CiStatus {
	target_repo_id := repo_id
	target_commit_hash := commit_hash
	target_branch := branch
	results := sql app.db {
		select from CiStatus where repo_id == target_repo_id && commit_hash == target_commit_hash
		&& branch == target_branch order by id desc limit 1
	} or { return none }
	if results.len == 0 {
		return none
	}
	return results[0]
}

// A known commit must be matched exactly. Falling back to the latest status on
// its branch would show an older pipeline on a newer, untested commit.
fn (mut app App) find_ci_status_for_tree(repo_id int, commit_hash string, branch string) ?CiStatus {
	if commit_hash != '' {
		return app.find_ci_status_for_commit(repo_id, commit_hash, branch)
	}
	return app.find_ci_status_for_branch(repo_id, branch)
}

fn (mut app App) find_ci_status_for_branch(repo_id int, branch string) ?CiStatus {
	target_repo_id := repo_id
	target_branch := branch
	results := sql app.db {
		select from CiStatus where repo_id == target_repo_id && branch == target_branch order by id desc limit 1
	} or { return none }
	if results.len == 0 {
		return none
	}
	return results[0]
}

fn (mut app App) find_ci_runs_for_repo(repo_id int) []CiStatus {
	return sql app.db {
		select from CiStatus where repo_id == repo_id order by id desc
	} or { []CiStatus{} }
}

fn (mut app App) repo_owns_ci_run(repo_id int, ci_run_id int) bool {
	app.find_ci_status_for_run(repo_id, ci_run_id) or { return false }
	return true
}

fn (mut app App) find_ci_status_for_run(repo_id int, ci_run_id int) ?CiStatus {
	if ci_run_id <= 0 {
		return none
	}
	target_run_id := ci_run_id
	results := sql app.db {
		select from CiStatus where ci_run_id == target_run_id
	} or { return none }
	// A duplicate local binding is ambiguous and must not authorize access to a
	// remote run or accept a callback for an arbitrary one of those rows.
	if results.len != 1 || results[0].repo_id != repo_id {
		return none
	}
	return results[0]
}

fn (mut app App) find_ci_statuses_for_run(ci_run_id int) []CiStatus {
	if ci_run_id <= 0 {
		return []CiStatus{}
	}
	target_run_id := ci_run_id
	return sql app.db {
		select from CiStatus where ci_run_id == target_run_id order by id desc
	} or { []CiStatus{} }
}

fn (mut app App) has_ci_status_reservation(repo_id int, commit_hash string, branch string) bool {
	target_repo_id := repo_id
	target_commit_hash := commit_hash
	target_branch := branch
	zero := 0
	count := sql app.db {
		select count from CiStatus where repo_id == target_repo_id && commit_hash == target_commit_hash
		&& branch == target_branch && ci_run_id < zero
	} or { 0 }
	return count > 0
}

fn (mut app App) add_ci_status(ci CiStatus) ! {
	if ci.repo_id <= 0 || !is_full_commit_oid(ci.commit_hash) || !is_safe_ref(ci.branch) {
		return error('invalid CI status identity')
	}
	sql app.db {
		insert ci into CiStatus
	}!
}

fn (mut app App) update_ci_status(repo_id int, commit_hash string, branch string, status CiStatusEnum) ! {
	existing := app.find_ci_status_for_commit(repo_id, commit_hash, branch) or { return }
	if !ci_status_transition_allowed(existing.status, status) {
		return
	}
	id := existing.id
	expected := existing.status
	updated := int(time.now().unix())
	sql app.db {
		update CiStatus set status = status, updated_at = updated where id == id && status == expected
	}!
}

fn (mut app App) upsert_ci_status(repo_id int, commit_hash string, branch string, status CiStatusEnum, ci_run_id int) ! {
	if repo_id <= 0 || ci_run_id <= 0 || !is_full_commit_oid(commit_hash) || !is_safe_ref(branch) {
		return error('invalid CI run identity')
	}

	// Select by both commit and branch: the same commit can legitimately run on
	// multiple branches with separate protection rules and pipeline histories.
	if existing := app.find_ci_status_for_commit(repo_id, commit_hash, branch) {
		if existing.ci_run_id == ci_run_id {
			bindings := app.find_ci_statuses_for_run(ci_run_id)
			if bindings.len != 1 || bindings[0].id != existing.id {
				return error('CI run id has an ambiguous local binding')
			}
			if !app.apply_ci_status_callback(repo_id, commit_hash, branch, ci_run_id, status)! {
				return error('CI run binding changed')
			}
			return
		}
	}

	// A runner id is an immutable attempt identity. Never reuse it for another
	// repository, branch, or commit, even if a compromised restart response
	// supplies a locally known id.
	if app.find_ci_statuses_for_run(ci_run_id).len > 0 {
		return error('CI run id is already bound')
	}
	now := int(time.now().unix())
	app.add_ci_status(CiStatus{
		repo_id:     repo_id
		commit_hash: commit_hash
		branch:      branch
		status:      status
		ci_run_id:   ci_run_id
		created_at:  now
		updated_at:  now
	})!
	// Defensively detect a concurrent duplicate binding. A database uniqueness
	// constraint can be added later without changing this invariant or API.
	bindings := app.find_ci_statuses_for_run(ci_run_id)
	if bindings.len != 1 || bindings[0].repo_id != repo_id || bindings[0].commit_hash != commit_hash
		|| bindings[0].branch != branch {
		return error('CI run id could not be bound unambiguously')
	}
	return
}

// begin_ci_status records a distinct outbound trigger before making the HTTP
// request. The negative random id is an internal reservation only; runner ids
// are required to be positive. A reservation lets concurrent trigger replies
// update only their own row without introducing a protocol-visible nonce.
fn (mut app App) begin_ci_status(repo_id int, commit_hash string, branch string) !int {
	if repo_id <= 0 || !is_full_commit_oid(commit_hash) || !is_safe_ref(branch) {
		return error('invalid CI run identity')
	}
	reservation := -int(rand.int_u64(2_147_483_646)!) - 1
	now := int(time.now().unix())
	app.add_ci_status(CiStatus{
		repo_id:     repo_id
		commit_hash: commit_hash
		branch:      branch
		status:      .pending
		ci_run_id:   reservation
		created_at:  now
		updated_at:  now
	})!
	return reservation
}

fn (mut app App) bind_ci_status_run(repo_id int, commit_hash string, branch string, reservation int, ci_run_id int) ! {
	if repo_id <= 0 || reservation >= 0 || ci_run_id <= 0 || !is_full_commit_oid(commit_hash)
		|| !is_safe_ref(branch) {
		return error('invalid CI run reservation')
	}
	if app.find_ci_statuses_for_run(ci_run_id).len > 0 {
		return error('CI run id is already bound')
	}
	target_repo_id := repo_id
	target_commit_hash := commit_hash
	target_branch := branch
	target_reservation := reservation
	target_run_id := ci_run_id
	reservations := sql app.db {
		select from CiStatus where repo_id == target_repo_id && commit_hash == target_commit_hash
		&& branch == target_branch && ci_run_id == target_reservation
	}!
	if reservations.len != 1 {
		return error('CI run reservation is missing or ambiguous')
	}
	status_id := reservations[0].id
	updated := int(time.now().unix())
	sql app.db {
		update CiStatus set ci_run_id = target_run_id, updated_at = updated where id == status_id
		&& ci_run_id == target_reservation
	}!
	bindings := app.find_ci_statuses_for_run(ci_run_id)
	if bindings.len != 1 || bindings[0].id != status_id || bindings[0].repo_id != repo_id
		|| bindings[0].commit_hash != commit_hash || bindings[0].branch != branch {
		// If another binder won the same runner id concurrently, put this row
		// back into its reservation state rather than leaving two identities.
		sql app.db {
			update CiStatus set ci_run_id = target_reservation where id == status_id
			&& ci_run_id == target_run_id
		} or {}
		return error('CI run reservation could not be bound')
	}
}

fn (mut app App) fail_ci_status_reservation(repo_id int, commit_hash string, branch string, reservation int) ! {
	if repo_id <= 0 || reservation >= 0 || !is_full_commit_oid(commit_hash) || !is_safe_ref(branch) {
		return error('invalid CI run reservation')
	}
	target_repo_id := repo_id
	target_commit_hash := commit_hash
	target_branch := branch
	target_reservation := reservation
	failed_run_id := 0
	failed_status := CiStatusEnum.failure
	updated := int(time.now().unix())
	sql app.db {
		update CiStatus set status = failed_status, ci_run_id = failed_run_id, updated_at = updated
		where repo_id == target_repo_id && commit_hash == target_commit_hash
		&& branch == target_branch && ci_run_id == target_reservation
	}!
}

// apply_ci_status_callback updates only the row already associated with the
// runner's positive id. In particular, it never changes ci_run_id and never
// creates a status for an unknown callback, so an old run cannot replace a
// newer run for the same commit.
fn (mut app App) apply_ci_status_callback(repo_id int, commit_hash string, branch string, ci_run_id int, status CiStatusEnum) !bool {
	if repo_id <= 0 || ci_run_id <= 0 || !is_full_commit_oid(commit_hash) || !is_safe_ref(branch) {
		return false
	}
	target_repo_id := repo_id
	target_commit_hash := commit_hash
	target_branch := branch
	target_run_id := ci_run_id
	target_status := status
	bindings := app.find_ci_statuses_for_run(ci_run_id)
	if bindings.len != 1 || bindings[0].repo_id != repo_id || bindings[0].commit_hash != commit_hash
		|| bindings[0].branch != branch {
		return false
	}
	for _ in 0 .. 3 {
		runs := sql app.db {
			select from CiStatus where repo_id == target_repo_id && commit_hash == target_commit_hash
			&& branch == target_branch && ci_run_id == target_run_id
		}!
		if runs.len != 1 {
			return false
		}
		current := runs[0].status
		if current == target_status || !ci_status_transition_allowed(current, target_status) {
			// Duplicate and out-of-order callbacks are acknowledged, but a
			// running state cannot regress and terminal states are immutable.
			return true
		}
		status_id := runs[0].id
		updated := int(time.now().unix())
		expected := current
		sql app.db {
			update CiStatus set status = target_status, updated_at = updated where id == status_id
			&& repo_id == target_repo_id && commit_hash == target_commit_hash
			&& branch == target_branch && ci_run_id == target_run_id && status == expected
		}!
		updated_runs := sql app.db {
			select from CiStatus where id == status_id && ci_run_id == target_run_id limit 1
		}!
		if updated_runs.len == 0 {
			return false
		}
		if updated_runs[0].status == target_status {
			return true
		}
		// Another callback won the conditional update. Re-evaluate the
		// transition so a terminal callback can still advance a running run.
	}
	return error('CI status changed concurrently')
}

fn ci_status_transition_allowed(current CiStatusEnum, next CiStatusEnum) bool {
	if current == next {
		return true
	}
	return match current {
		.pending {
			next in [.running, .success, .failure, .cancelled, .timed_out]
		}
		.running {
			next in [.success, .failure, .cancelled, .timed_out]
		}
		.success, .failure, .cancelled, .timed_out {
			false
		}
	}
}

// A run can finish quickly enough to call back while the trigger request is
// still returning its newly allocated run id. Wait briefly for that id to be
// bound to the reservation. This avoids losing an early terminal callback,
// while exact-id matching still prevents it from claiming another attempt.
fn (mut app App) apply_ci_status_callback_after_registration(repo_id int, commit_hash string, branch string, ci_run_id int, status CiStatusEnum) !bool {
	if app.apply_ci_status_callback(repo_id, commit_hash, branch, ci_run_id, status)! {
		return true
	}
	for _ in 0 .. 20 {
		if !app.has_ci_status_reservation(repo_id, commit_hash, branch) {
			return false
		}
		time.sleep(25 * time.millisecond)
		if app.apply_ci_status_callback(repo_id, commit_hash, branch, ci_run_id, status)! {
			return true
		}
	}
	return false
}

fn (mut app App) delete_repo_ci_statuses(repo_id int) ! {
	sql app.db {
		delete from CiStatus where repo_id == repo_id
	}!
}

fn (ci &CiStatus) relative_time() string {
	if ci.updated_at == 0 && ci.created_at == 0 {
		return ''
	}
	t := if ci.updated_at > 0 { ci.updated_at } else { ci.created_at }
	return time.unix(t).relative()
}
