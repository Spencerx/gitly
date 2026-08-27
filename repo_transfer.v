// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

struct RepoTransfer {
	id           int @[primary; sql: serial]
	repo_id      int @[unique]
	requested_by int
	recipient_id int
	created_at   int
}

struct RepoTransferView {
	transfer RepoTransfer
	repo     Repo
	from     User
}

fn (mut app App) request_repo_transfer(repo_id int, requested_by int, recipient_id int) ! {
	if repo_id <= 0 || requested_by <= 0 || recipient_id <= 0 {
		return error('invalid repository transfer')
	}
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	sql tx {
		delete from RepoTransfer where repo_id == repo_id
	}!
	transfer := RepoTransfer{
		repo_id:      repo_id
		requested_by: requested_by
		recipient_id: recipient_id
		created_at:   int(time.now().unix())
	}
	sql tx {
		insert transfer into RepoTransfer
	}!
	tx.commit()!
	committed = true
}

// accept_repo_transfer_atomic serializes acceptance with replacement,
// revocation, and competing acceptance requests. The filesystem rename cannot
// participate in a database transaction, so it is performed while all
// authoritative rows are locked and is moved back if any database step rolls
// back.
fn (mut app App) accept_repo_transfer_atomic(transfer_id int, recipient_id int) !Repo {
	if transfer_id <= 0 || recipient_id <= 0 {
		return error('invalid repository transfer')
	}
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	mut moved := false
	mut source_path := ''
	mut destination_path := ''
	defer {
		if !committed {
			tx.rollback() or {}
			if moved {
				os.mv(destination_path, source_path) or {
					app.warn('Could not restore repository after failed transfer: ${err}')
				}
			}
		}
	}

	// A harmless UPDATE works as a row lock on PostgreSQL and also acquires
	// SQLite's write reservation before any filesystem state changes.
	claimed := tx.execute('update ${sql_table('RepoTransfer')} set ${sql_table('id')} = ${sql_table('id')}
		where ${sql_table('id')} = ${transfer_id}
		and ${sql_table('recipient_id')} = ${recipient_id}
		returning ${sql_table('id')}')!
	if claimed.len != 1 {
		return error('repository transfer is no longer available')
	}
	target_transfer_id := transfer_id
	transfers := sql tx {
		select from RepoTransfer where id == target_transfer_id limit 1
	}!
	if transfers.len != 1 || transfers[0].recipient_id != recipient_id {
		return error('repository transfer is no longer available')
	}
	transfer := transfers[0]

	locked_repo := tx.execute('update ${sql_table('Repo')} set ${sql_table('id')} = ${sql_table('id')}
		where ${sql_table('id')} = ${transfer.repo_id}
		and ${sql_table('is_deleted')} is false
		returning ${sql_table('id')}')!
	if locked_repo.len != 1 {
		invalid_transfer_id := transfer.id
		sql tx {
			delete from RepoTransfer where id == invalid_transfer_id
		}!
		tx.commit()!
		committed = true
		return error('repository is no longer available')
	}
	target_repo_id := transfer.repo_id
	repos := sql tx {
		select from Repo where id == target_repo_id && is_deleted == false limit 1
	}!
	if repos.len != 1 {
		return error('repository is no longer available')
	}
	repo := repos[0]

	locked_recipient := tx.execute('update ${sql_table('User')} set ${sql_table('id')} = ${sql_table('id')}
		where ${sql_table('id')} = ${recipient_id}
		returning ${sql_table('id')}')!
	if locked_recipient.len != 1 {
		return error('transfer recipient is no longer available')
	}
	target_recipient_id := recipient_id
	recipients := sql tx {
		select from User where id == target_recipient_id limit 1
	}!
	if recipients.len != 1 || !recipients[0].is_registered || recipients[0].is_blocked {
		return error('transfer recipient is not active')
	}
	recipient := recipients[0]

	// Personal namespace ownership is carried by Repo.user_id. Organization
	// ownership requires a currently locked administrator membership, so a
	// concurrent revocation cannot pass a stale preflight check.
	owner_name := repo.user_name
	orgs := sql tx {
		select from Org where name == owner_name limit 1
	}!
	mut requester_is_owner := false
	if orgs.len == 1 {
		org_id := orgs[0].id
		locked_org := tx.execute('update ${sql_table('Org')} set ${sql_table('id')} = ${sql_table('id')}
			where ${sql_table('id')} = ${org_id}
			returning ${sql_table('id')}')!
		if locked_org.len == 1 {
			locked_membership := tx.execute('update ${sql_table('OrgMember')} set ${sql_table('id')} = ${sql_table('id')}
				where ${sql_table('org_id')} = ${org_id}
				and ${sql_table('user_id')} = ${transfer.requested_by}
				and ${sql_table('role')} = ${sql_literal('admin')}
				returning ${sql_table('id')}')!
			requester_is_owner = locked_membership.len == 1
		}
	} else {
		requester_is_owner = repo.user_id == transfer.requested_by
	}
	if !requester_is_owner {
		revoked_transfer_id := transfer.id
		sql tx {
			delete from RepoTransfer where id == revoked_transfer_id
		}!
		tx.commit()!
		committed = true
		return error('transfer requester no longer owns the repository')
	}

	destination_owner := recipient.username
	repository_name := repo.name
	existing_destination := sql tx {
		select from Repo where user_name == destination_owner && name == repository_name
		&& is_deleted == false limit 1
	}!
	if existing_destination.len > 0 {
		return error('destination repository already exists')
	}
	if !recipient.is_admin {
		active_repo_count := sql tx {
			select count from Repo where user_id == target_recipient_id && is_deleted == false
		}!
		if active_repo_count >= max_user_repos {
			return error('transfer recipient has reached the repository limit')
		}
	}
	if repo.user_name == recipient.username {
		return error('repository is already in the destination namespace')
	}

	destination_dir := os.join_path(app.config.repo_storage_path, recipient.username)
	os.mkdir_all(destination_dir)!
	source_path = repo.git_dir
	destination_path = os.join_path(destination_dir, repo.name)
	if source_path == '' || !os.exists(source_path) {
		return error('repository directory is unavailable')
	}
	if os.exists(destination_path) {
		return error('destination repository directory already exists')
	}
	os.mv(source_path, destination_path)!
	moved = true

	repo_id := repo.id
	destination_user_id := recipient.id
	destination_user_name := recipient.username
	new_git_dir := destination_path
	sql tx {
		update Repo set user_id = destination_user_id, user_name = destination_user_name,
		git_dir = new_git_dir where id == repo_id && is_deleted == false
	}!
	consumed_transfer_id := transfer.id
	sql tx {
		delete from RepoTransfer where id == consumed_transfer_id
	}!
	updated_repos := sql tx {
		select from Repo where id == repo_id && user_id == destination_user_id
		&& user_name == destination_user_name && git_dir == new_git_dir && is_deleted == false limit 1
	}!
	remaining_transfer := sql tx {
		select count from RepoTransfer where id == consumed_transfer_id
	}!
	if updated_repos.len != 1 || remaining_transfer != 0 {
		return error('repository transfer could not be committed')
	}

	tx.commit()!
	committed = true
	moved = false
	return updated_repos[0]
}

fn (app App) find_repo_transfer(id int) ?RepoTransfer {
	rows := sql app.db {
		select from RepoTransfer where id == id limit 1
	} or { []RepoTransfer{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) find_repo_transfers_for_user(user_id int) []RepoTransferView {
	transfers := sql app.db {
		select from RepoTransfer where recipient_id == user_id order by id desc
	} or { []RepoTransfer{} }
	mut result := []RepoTransferView{cap: transfers.len}
	for transfer in transfers {
		repo := app.find_repo_by_id(transfer.repo_id) or {
			app.delete_repo_transfer(transfer.id) or {}
			continue
		}
		from := app.get_user_by_id(transfer.requested_by) or {
			placeholder_user(transfer.requested_by)
		}
		result << RepoTransferView{
			transfer: transfer
			repo:     repo
			from:     from
		}
	}
	return result
}

fn (mut app App) delete_repo_transfer(id int) ! {
	sql app.db {
		delete from RepoTransfer where id == id
	}!
}

fn (mut app App) delete_repo_transfer_for_repo(repo_id int) ! {
	sql app.db {
		delete from RepoTransfer where repo_id == repo_id
	}!
}
