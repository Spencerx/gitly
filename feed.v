module main

import time

// now only for commits
struct FeedItem {
	id          int
	author_name string
	created_at  time.Time
	repo_name   string
	repo_owner  string
	branch_name string
	message     string
}

const feed_items_per_page = 30

fn (mut app App) find_accessible_watching_repo_ids(user_id int) []int {
	mut result := []int{}
	for repo_id in app.find_watching_repo_ids(user_id) {
		repo := app.find_repo_by_id(repo_id) or { continue }
		if app.user_has_repo_read_access(user_id, repo) {
			result << repo_id
		}
	}
	return result
}

fn (mut app App) build_user_feed_as_page(user_id int, offset int) []FeedItem {
	mut feed := []FeedItem{}
	repo_ids := app.find_accessible_watching_repo_ids(user_id)
	if repo_ids.len == 0 {
		return []
	}
	where_repo_ids := repo_ids.map(it.str()).join(', ')

	commits := db_exec_values(mut app.db, '
		select c.author, c.hash, c.created_at, c.repo_id, bc.branch_id, c.message
			from ${sql_table('Commit')} c
			join ${sql_table('BranchCommit')} bc on bc.commit_id = c.id
			where c.repo_id in (${where_repo_ids}) order by c.created_at desc
			limit ${feed_items_per_page} offset ${offset}') or {
		return []
	}
	mut item_id := 0

	for commit in commits {
		vals := commit
		author_name := vals[0]
		commit_hash := vals[1]
		created_at_unix := vals[2].int()
		repo_id := vals[3].int()
		branch_id := vals[4].int()
		commit_message := vals[5]

		repo := app.find_repo_by_id(repo_id) or { continue }
		repo_owner := repo.user_name
		branch := app.find_repo_branch_by_id(repo_id, branch_id)
		created_at := time.unix(created_at_unix)

		item := FeedItem{
			id:          item_id++
			author_name: author_name
			created_at:  created_at
			repo_name:   repo.name
			repo_owner:  repo_owner
			branch_name: branch.name
			message:     '${commit_message} (${commit_hash})'
		}

		feed << item
	}

	return feed
}

fn (mut app App) get_feed_items_count(user_id int) int {
	repo_ids := app.find_accessible_watching_repo_ids(user_id)
	if repo_ids.len == 0 {
		return 0
	}
	where_repo_ids := repo_ids.map(it.str()).join(', ')

	count_result := db_exec_values(mut app.db,
		'select count(c.id) from ${sql_table('Commit')} c join ${sql_table('BranchCommit')} bc on bc.commit_id = c.id where c.repo_id in (${where_repo_ids})') or {
		return 0
	}

	return count_result.first().first().int()
}
