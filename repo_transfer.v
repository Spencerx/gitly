// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

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
	sql app.db {
		delete from RepoTransfer where repo_id == repo_id
	}!
	transfer := RepoTransfer{
		repo_id:      repo_id
		requested_by: requested_by
		recipient_id: recipient_id
		created_at:   int(time.now().unix())
	}
	sql app.db {
		insert transfer into RepoTransfer
	}!
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
