module main

import veb
import time
import api
import git

@['/api/v1/:user/:repo_name/:branch_name/commits/count']
fn (mut app App) handle_commits_count(mut ctx Context, username string, repo_name string, branch_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.json_error('Not found')
	}
	if !is_safe_ref(branch_name) {
		return ctx.json_error('Not found')
	}

	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	count := app.get_repo_commit_count(repo.id, branch.id)

	// app.debug("${branch} ${count}" )

	return ctx.json(api.ApiCommitCount{
		success: true
		result:  count
	})
}

@['/:username/:repo_name/:branch_name/commits/:page']
pub fn (mut app App) commits(mut ctx Context, username string, repo_name string, branch_name string, page string) veb.Result {
	if !is_safe_ref(branch_name) {
		return ctx.not_found()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	commits_count := app.get_repo_commit_count(repo.id, branch.id)

	// FIXME: b_author always false
	b_author := false
	page_count := calculate_pages(commits_count, commits_per_page)
	page_i := normalize_page(page, page_count)
	offset := commits_per_page * page_i
	is_first_page := check_first_page(page_i)
	is_last_page := check_last_page(commits_count, offset, commits_per_page)
	prev_page, next_page := generate_prev_next_pages(page_i)

	mut commits := app.find_repo_commits_as_page(repo.id, branch.id, offset)

	mut d_commits := map[string][]Commit{}
	mut author_avatars := map[int]string{}
	mut author_usernames := map[int]string{}
	for commit in commits {
		date := time.unix(commit.created_at)
		author := commit.author_id.str()
		date_s := date.custom_format('MMMM D, YYYY')

		if b_author {
			if author !in d_commits {
				d_commits[author] = []Commit{}
			}
			d_commits[author] << commit
		} else {
			if date_s !in d_commits {
				d_commits[date_s] = []Commit{}
			}
			d_commits[date_s] << commit
		}

		if commit.author_id != 0 && commit.author_id !in author_avatars {
			if user := app.get_user_by_id(commit.author_id) {
				author_avatars[commit.author_id] = app.prepare_user_avatar_url(user.avatar)
				author_usernames[commit.author_id] = user.username
			}
		}
	}

	return $veb.html()
}

@['/:username/:repo_name/commit/:hash']
pub fn (mut app App) commit(mut ctx Context, username string, repo_name string, hash string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	is_patch_request := hash.ends_with('.patch')

	if is_patch_request {
		commit_hash := hash.trim_string_right('.patch')
		patch := repo.get_commit_patch(commit_hash) or { return ctx.not_found() }

		return ctx.ok(patch)
	}
	if !is_valid_commit_hash(hash) {
		return ctx.not_found()
	}

	patch_url := '/${username}/${repo_name}/commit/${hash}.patch'
	commit := app.find_repo_commit_by_hash(repo.id, hash)
	if commit.hash == '' {
		return ctx.not_found()
	}
	diff_result := git.Git.exec_in_dir(repo.git_dir, ['show', '--no-color', '--pretty=format:',
		commit.hash])
	if diff_result.exit_code != 0 {
		return ctx.not_found()
	}
	raw_diff := diff_result.output
	file_diffs := parse_unified_diff(raw_diff)

	mut all_adds := 0
	mut all_dels := 0
	for fd in file_diffs {
		all_adds += fd.additions
		all_dels += fd.deletions
	}

	return $veb.html()
}
