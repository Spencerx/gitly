module main

import veb
import api

@['/api/v1/:user/:repo_name/branches/count']
fn (mut app App) handle_branch_count(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}

	count := app.get_count_repo_branches(repo.id)

	return ctx.json(api.ApiBranchCount{
		success: true
		result:  count
	})
}

@['/:user/:repo/branches']
pub fn (mut app App) branches(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
	}
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	mut branches := app.get_all_repo_branches(repo.id)
	for mut branch in branches {
		branch.is_protected = app.branch_is_protected(repo.id, branch.name)
	}
	return $veb.html()
}
