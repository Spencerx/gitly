// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

struct ApiRepoView {
	id                 int
	name               string
	full_name          string
	user_name          string
	description        string
	is_public          bool
	stars              int
	open_issues        int
	open_prs           int
	branches           int
	created_at         int
	required_approvals int
	forked_from_id     int
	forks_count        int
	http_url           string
	ssh_url            string
}

struct ApiIssueView {
	id             int
	number         int
	repo_id        int
	title          string
	body           string
	author         string
	status         string
	comments_count int
	created_at     int
}

struct ApiPullView {
	id                  int
	repo_id             int
	title               string
	description         string
	head_branch         string
	head_repo_id        int
	base_branch         string
	author              string
	status              string
	comments_count      int
	created_at          int
	merged_at           int
	approvals           int
	required_approvals  int
	approvals_satisfied bool
}

struct ApiProjectMemberView {
	id           int
	user_id      int
	username     string
	role         string
	access_level int
}

struct ApiProtectedBranchView {
	id           int
	pattern      string
	push_access  int
	merge_access int
}

struct ApiApprovalView {
	user_id    int
	username   string
	created_at int
}

struct ApiApprovalStatusView {
	count       int
	required    int
	satisfied   bool
	approved_by []ApiApprovalView
}

struct ApiUserView {
	id        int
	username  string
	full_name string
	avatar    string
}

struct ApiCommentView {
	id         int
	author     string
	text       string
	created_at int
}

fn (mut app App) repo_to_api(repo Repo) ApiRepoView {
	relation := app.find_fork_by_repo(repo.id) or { RepoFork{} }
	return ApiRepoView{
		id:                 repo.id
		name:               repo.name
		full_name:          '${repo.user_name}/${repo.name}'
		user_name:          repo.user_name
		description:        repo.description
		is_public:          repo.is_public
		stars:              repo.nr_stars
		open_issues:        repo.nr_open_issues
		open_prs:           repo.nr_open_prs
		branches:           repo.nr_branches
		created_at:         repo.created_at
		required_approvals: repo.required_approvals
		forked_from_id:     relation.source_repo_id
		forks_count:        app.count_repo_forks(repo.id)
		http_url:           app.generate_clone_url(repo)
		ssh_url:            if app.config.ssh_enabled {
			app.generate_ssh_clone_url(repo)
		} else {
			''
		}
	}
}

fn (mut app App) issue_to_api(issue Issue) ApiIssueView {
	author := app.get_username_by_id(issue.author_id) or { '' }
	status := if issue.status == .closed { 'closed' } else { 'open' }
	return ApiIssueView{
		id:             issue.id
		number:         issue.id
		repo_id:        issue.repo_id
		title:          issue.title
		body:           issue.text
		author:         author
		status:         status
		comments_count: issue.comments_count
		created_at:     issue.created_at
	}
}

fn (mut app App) pr_to_api(pr PullRequest) ApiPullView {
	author := app.get_username_by_id(pr.author_id) or { '' }
	status := match unsafe { PrStatus(pr.status) } {
		.open { 'open' }
		.closed { 'closed' }
		.merged { 'merged' }
	}

	repo := app.find_repo_by_id(pr.repo_id) or { Repo{} }
	approval_count := app.pull_request_approval_count(pr.id)
	return ApiPullView{
		id:                  pr.id
		repo_id:             pr.repo_id
		title:               pr.title
		description:         pr.description
		head_branch:         pr.head_branch
		head_repo_id:        if pr.head_repo_id > 0 { pr.head_repo_id } else { pr.repo_id }
		base_branch:         pr.base_branch
		author:              author
		status:              status
		comments_count:      pr.comments_count
		created_at:          pr.created_at
		merged_at:           pr.merged_at
		approvals:           approval_count
		required_approvals:  repo.required_approvals
		approvals_satisfied: approval_count >= repo.required_approvals
	}
}

fn (ctx &Context) api_bearer_token() string {
	header := ctx.get_header(.authorization) or { return '' }
	parts := header.fields()
	if parts.len != 2 || parts[0].to_lower() != 'bearer' {
		return ''
	}
	return parts[1]
}

fn (mut app App) api_user_from_ctx(ctx &Context) ?User {
	token := ctx.api_bearer_token()
	if token == '' {
		if ctx.logged_in {
			return ctx.user
		}
		return none
	}
	return app.user_for_api_token(token)
}

fn (mut ctx Context) api_unauthorized() veb.Result {
	ctx.send_custom_error(401, 'Unauthorized')
	return ctx.json({
		'success': 'false'
		'message': 'authentication required'
	})
}

fn (mut ctx Context) api_not_found() veb.Result {
	ctx.send_custom_error(404, 'Not Found')
	return ctx.json({
		'success': 'false'
		'message': 'not found'
	})
}

@['/api/v1/me']
pub fn (mut app App) api_v1_me(mut ctx Context) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	return ctx.json(ApiUserView{
		id:        user.id
		username:  user.username
		full_name: user.full_name
		avatar:    user.avatar
	})
}

@['/api/v1/users/:username']
pub fn (mut app App) api_v1_user(mut ctx Context, username string) veb.Result {
	user := app.get_user_by_username(username) or { return ctx.api_not_found() }
	return ctx.json(ApiUserView{
		id:        user.id
		username:  user.username
		full_name: user.full_name
		avatar:    user.avatar
	})
}

@['/api/v1/users/:username/repos']
pub fn (mut app App) api_v1_user_repos(mut ctx Context, username string) veb.Result {
	user := app.get_user_by_username(username) or { return ctx.api_not_found() }
	repos := app.find_user_public_repos(user.id)
	mut out := []ApiRepoView{cap: repos.len}
	for r in repos {
		out << app.repo_to_api(r)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name']
pub fn (mut app App) api_v1_repo(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	return ctx.json(app.repo_to_api(repo))
}

@['/api/v1/repos/:username/:repo_name/issues']
pub fn (mut app App) api_v1_repo_issues(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	issues := app.find_repo_issues_as_page(repo.id, 0)
	mut out := []ApiIssueView{cap: issues.len}
	for i in issues {
		out << app.issue_to_api(i)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/issues/:id']
pub fn (mut app App) api_v1_repo_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	issue := app.find_issue_by_id(id.int()) or { return ctx.api_not_found() }
	if issue.repo_id != repo.id {
		return ctx.api_not_found()
	}
	return ctx.json(app.issue_to_api(issue))
}

@['/api/v1/repos/:username/:repo_name/issues'; post]
pub fn (mut app App) api_v1_create_issue(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	title := ctx.form['title']
	body := ctx.form['body']
	if !valid_title(title) || !valid_body(body) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'title is required and content must be within size limits'
		})
	}
	new_id := app.add_issue_returning_id(repo.id, user.id, title, body) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to create issue'
		})
	}
	issue := app.find_issue_by_id(new_id) or { return ctx.api_not_found() }
	return ctx.json(app.issue_to_api(issue))
}

@['/api/v1/repos/:username/:repo_name/pulls']
pub fn (mut app App) api_v1_repo_pulls(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	prs := app.find_repo_pull_requests(repo.id, .open)
	mut out := []ApiPullView{cap: prs.len}
	for pr in prs {
		out << app.pr_to_api(pr)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/pulls/:id']
pub fn (mut app App) api_v1_repo_pull(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.api_not_found() }
	if pr.repo_id != repo.id {
		return ctx.api_not_found()
	}
	return ctx.json(app.pr_to_api(pr))
}

@['/api/v1/repos/:username/:repo_name/pulls/:id/comments']
pub fn (mut app App) api_v1_pull_comments(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.api_not_found() }
	if pr.repo_id != repo.id {
		return ctx.api_not_found()
	}
	comments := app.get_pr_comments(pr.id)
	mut out := []ApiCommentView{cap: comments.len}
	for c in comments {
		author := app.get_username_by_id(c.author_id) or { '' }
		out << ApiCommentView{
			id:         c.id
			author:     author
			text:       c.text
			created_at: c.created_at
		}
	}
	return ctx.json(out)
}

struct ApiDiscussionView {
	id             int
	repo_id        int
	title          string
	body           string
	category       string
	author         string
	is_locked      bool
	is_answered    bool
	answer_id      int
	comments_count int
	created_at     int
}

struct ApiMilestoneView {
	id          int
	repo_id     int
	title       string
	description string
	due_date    int
	is_closed   bool
	created_at  int
}

struct ApiProjectView {
	id          int
	repo_id     int
	name        string
	description string
	created_at  int
}

struct ApiProjectCardView {
	id         int
	column_id  int
	title      string
	note       string
	position   int
	issue_id   int
	created_at int
}

struct ApiProjectColumnView {
	id         int
	project_id int
	name       string
	position   int
	cards      []ApiProjectCardView
}

struct ApiProjectDetailView {
	project ApiProjectView
	columns []ApiProjectColumnView
}

struct ApiWebhookView {
	id            int
	repo_id       int
	url           string
	events        []string
	is_active     bool
	last_status   int
	last_delivery int
	created_at    int
}

fn (mut app App) discussion_to_api(d Discussion) ApiDiscussionView {
	author := app.get_username_by_id(d.author_id) or { '' }
	return ApiDiscussionView{
		id:             d.id
		repo_id:        d.repo_id
		title:          d.title
		body:           d.body
		category:       d.category
		author:         author
		is_locked:      d.is_locked
		is_answered:    d.is_answered
		answer_id:      d.answer_id
		comments_count: d.comments_count
		created_at:     d.created_at
	}
}

fn (mut app App) milestone_to_api(m Milestone) ApiMilestoneView {
	return ApiMilestoneView{
		id:          m.id
		repo_id:     m.repo_id
		title:       m.title
		description: m.description
		due_date:    m.due_date
		is_closed:   m.is_closed
		created_at:  m.created_at
	}
}

fn (mut app App) project_to_api(p Project) ApiProjectView {
	return ApiProjectView{
		id:          p.id
		repo_id:     p.repo_id
		name:        p.name
		description: p.description
		created_at:  p.created_at
	}
}

fn (mut app App) project_card_to_api(c ProjectCard) ApiProjectCardView {
	return ApiProjectCardView{
		id:         c.id
		column_id:  c.column_id
		title:      c.title
		note:       c.note
		position:   c.position
		issue_id:   c.issue_id
		created_at: c.created_at
	}
}

fn (w &Webhook) to_api() ApiWebhookView {
	return ApiWebhookView{
		id:            w.id
		repo_id:       w.repo_id
		url:           w.url
		events:        w.event_list()
		is_active:     w.is_active
		last_status:   w.last_status
		last_delivery: w.last_delivery
		created_at:    w.created_at
	}
}

@['/api/v1/repos/:username/:repo_name/discussions']
pub fn (mut app App) api_v1_repo_discussions(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.discussions_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	discussions := app.list_repo_discussions(repo.id)
	mut out := []ApiDiscussionView{cap: discussions.len}
	for d in discussions {
		out << app.discussion_to_api(d)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/discussions/:id']
pub fn (mut app App) api_v1_repo_discussion(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.discussions_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	discussion := app.find_discussion(id.int()) or { return ctx.api_not_found() }
	if discussion.repo_id != repo.id {
		return ctx.api_not_found()
	}
	return ctx.json(app.discussion_to_api(discussion))
}

@['/api/v1/repos/:username/:repo_name/discussions'; post]
pub fn (mut app App) api_v1_create_discussion(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.discussions_enabled() {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	title := ctx.form['title']
	body := ctx.form['body']
	raw_cat := ctx.form['category']
	if !valid_title(title) || !valid_body(body) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'title is required and content must be within size limits'
		})
	}
	cat := if raw_cat in ['general', 'qa', 'announcement', 'idea'] { raw_cat } else { 'general' }
	new_id := app.add_discussion(repo.id, user.id, title, body, cat) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to create discussion'
		})
	}
	discussion := app.find_discussion(new_id) or { return ctx.api_not_found() }
	return ctx.json(app.discussion_to_api(discussion))
}

@['/api/v1/repos/:username/:repo_name/discussions/:id/comments']
pub fn (mut app App) api_v1_discussion_comments(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.discussions_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	discussion := app.find_discussion(id.int()) or { return ctx.api_not_found() }
	if discussion.repo_id != repo.id {
		return ctx.api_not_found()
	}
	comments := app.get_discussion_comments(discussion.id)
	mut out := []ApiCommentView{cap: comments.len}
	for c in comments {
		author := app.get_username_by_id(c.author_id) or { '' }
		out << ApiCommentView{
			id:         c.id
			author:     author
			text:       c.text
			created_at: c.created_at
		}
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/discussions/:id/comments'; post]
pub fn (mut app App) api_v1_create_discussion_comment(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.discussions_enabled() {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	discussion := app.find_discussion(id.int()) or { return ctx.api_not_found() }
	if discussion.repo_id != repo.id {
		return ctx.api_not_found()
	}
	if discussion.is_locked {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'discussion is locked'
		})
	}
	text := ctx.form['text']
	if !valid_comment(text) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'text is required and must be within size limits'
		})
	}
	app.add_discussion_comment(discussion.id, user.id, text) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to add comment'
		})
	}
	return ctx.json({
		'success': 'true'
	})
}

@['/api/v1/repos/:username/:repo_name/milestones']
pub fn (mut app App) api_v1_repo_milestones(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.milestones_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	milestones := app.list_repo_milestones(repo.id)
	mut out := []ApiMilestoneView{cap: milestones.len}
	for m in milestones {
		out << app.milestone_to_api(m)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/milestones/:id']
pub fn (mut app App) api_v1_repo_milestone(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.milestones_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	milestone := app.find_milestone(id.int()) or { return ctx.api_not_found() }
	if milestone.repo_id != repo.id {
		return ctx.api_not_found()
	}
	return ctx.json(app.milestone_to_api(milestone))
}

@['/api/v1/repos/:username/:repo_name/milestones'; post]
pub fn (mut app App) api_v1_create_milestone(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.milestones_enabled() {
		return ctx.api_not_found()
	}
	if !app.user_can_write_repo(user.id, repo) {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Developer access is required to create milestones'
		})
	}
	title := ctx.form['title']
	desc := ctx.form['description']
	due := parse_yyyy_mm_dd(ctx.form['due_date'])
	if !valid_title(title) || !valid_body(desc) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'title is required and content must be within size limits'
		})
	}
	new_id := app.add_milestone(repo.id, title, desc, due) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to create milestone'
		})
	}
	milestone := app.find_milestone(new_id) or { return ctx.api_not_found() }
	return ctx.json(app.milestone_to_api(milestone))
}

@['/api/v1/repos/:username/:repo_name/projects']
pub fn (mut app App) api_v1_repo_projects(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.projects_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	projects := app.list_repo_projects(repo.id)
	mut out := []ApiProjectView{cap: projects.len}
	for p in projects {
		out << app.project_to_api(p)
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/projects/:id']
pub fn (mut app App) api_v1_repo_project(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.projects_enabled() {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	project := app.find_project(id.int()) or { return ctx.api_not_found() }
	if project.repo_id != repo.id {
		return ctx.api_not_found()
	}
	columns := app.list_project_columns(project.id)
	mut col_views := []ApiProjectColumnView{cap: columns.len}
	for col in columns {
		cards := app.list_project_cards(col.id)
		mut card_views := []ApiProjectCardView{cap: cards.len}
		for c in cards {
			card_views << app.project_card_to_api(c)
		}
		col_views << ApiProjectColumnView{
			id:         col.id
			project_id: col.project_id
			name:       col.name
			position:   col.position
			cards:      card_views
		}
	}
	return ctx.json(ApiProjectDetailView{
		project: app.project_to_api(project)
		columns: col_views
	})
}

@['/api/v1/repos/:username/:repo_name/projects'; post]
pub fn (mut app App) api_v1_create_project(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !repo.projects_enabled() {
		return ctx.api_not_found()
	}
	if !app.user_can_write_repo(user.id, repo) {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Developer access is required to create projects'
		})
	}
	name := ctx.form['name']
	desc := ctx.form['description']
	if !valid_short_name(name) || !valid_body(desc) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'name is required and content must be within size limits'
		})
	}
	new_id := app.add_project(repo.id, name, desc) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to create project'
		})
	}
	project := app.find_project(new_id) or { return ctx.api_not_found() }
	return ctx.json(app.project_to_api(project))
}

@['/api/v1/repos/:username/:repo_name/webhooks']
pub fn (mut app App) api_v1_repo_webhooks(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		return ctx.api_not_found()
	}
	hooks := app.list_repo_webhooks(repo.id)
	mut out := []ApiWebhookView{cap: hooks.len}
	for w in hooks {
		out << w.to_api()
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/webhooks/:id']
pub fn (mut app App) api_v1_repo_webhook(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		return ctx.api_not_found()
	}
	wh := app.find_webhook_by_id(id.int()) or { return ctx.api_not_found() }
	if wh.repo_id != repo.id {
		return ctx.api_not_found()
	}
	return ctx.json(wh.to_api())
}

@['/api/v1/repos/:username/:repo_name/webhooks'; post]
pub fn (mut app App) api_v1_create_webhook(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required to create webhooks'
		})
	}
	url := ctx.form['url'].trim_space()
	secret := ctx.form['secret']
	events := ctx.form['events'].trim_space()
	if url == '' || url.len > max_clone_url_len || secret.len > max_webhook_secret_len
		|| !is_safe_webhook_url(url) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'valid http(s) url is required'
		})
	}
	events_str := if events == '' { 'push,issue,pr,comment,release' } else { events }
	app.add_webhook(repo.id, url, secret, events_str) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to create webhook'
		})
	}
	hooks := app.list_repo_webhooks(repo.id)
	if hooks.len == 0 {
		return ctx.api_not_found()
	}
	return ctx.json(hooks[0].to_api())
}

@['/api/v1/repos/:username/:repo_name/members']
pub fn (mut app App) api_v1_repo_members(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	members := app.find_project_members(repo.id)
	mut out := []ApiProjectMemberView{cap: members.len}
	for item in members {
		out << ApiProjectMemberView{
			id:           item.member.id
			user_id:      item.user.id
			username:     item.user.username
			role:         item.member.role
			access_level: project_role_access_level(item.member.role)
		}
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/members'; post]
pub fn (mut app App) api_v1_add_repo_member(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	target := app.get_user_by_username(ctx.form['username'].trim_space().to_lower()) or {
		return ctx.api_not_found()
	}
	role := ctx.form['role'].trim_space().to_lower()
	if !target.is_registered || target.is_blocked || !valid_project_member_role(role) {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'invalid member or role'
		})
	}
	if app.repo_access_level(target.id, repo) >= project_access_owner {
		ctx.send_custom_error(409, 'Conflict')
		return ctx.json({
			'success': 'false'
			'message': 'the repository owner already has full access'
		})
	}
	app.add_project_member(repo.id, target.id, role) or {
		ctx.send_custom_error(409, 'Conflict')
		return ctx.json({
			'success': 'false'
			'message': 'the user is already a direct member'
		})
	}
	return ctx.json(ApiProjectMemberView{
		id:           db_last_insert_id(mut app.db)
		user_id:      target.id
		username:     target.username
		role:         role
		access_level: project_role_access_level(role)
	})
}

@['/api/v1/repos/:username/:repo_name/members/:id'; post]
pub fn (mut app App) api_v1_update_repo_member(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	member := app.find_project_member_by_id(repo.id, id.int()) or { return ctx.api_not_found() }
	role := ctx.form['role'].trim_space().to_lower()
	app.update_project_member_role(repo.id, member.id, role) or {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'invalid member role'
		})
	}
	target := app.get_user_by_id(member.user_id) or { return ctx.api_not_found() }
	return ctx.json(ApiProjectMemberView{
		id:           member.id
		user_id:      target.id
		username:     target.username
		role:         role
		access_level: project_role_access_level(role)
	})
}

@['/api/v1/repos/:username/:repo_name/members/:id/delete'; post]
pub fn (mut app App) api_v1_delete_repo_member(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	member := app.find_project_member_by_id(repo.id, id.int()) or { return ctx.api_not_found() }
	app.remove_project_member(repo.id, member.id) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to remove member'
		})
	}
	return ctx.json({
		'success': 'true'
	})
}

@['/api/v1/repos/:username/:repo_name/protected-branches']
pub fn (mut app App) api_v1_protected_branches(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	rules := app.find_protected_branches(repo.id)
	mut out := []ApiProtectedBranchView{cap: rules.len}
	for rule in rules {
		out << ApiProtectedBranchView{
			id:           rule.id
			pattern:      rule.pattern
			push_access:  rule.push_access
			merge_access: rule.merge_access
		}
	}
	return ctx.json(out)
}

@['/api/v1/repos/:username/:repo_name/protected-branches'; post]
pub fn (mut app App) api_v1_protect_branch(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	pattern := ctx.form['pattern'].trim_space()
	push_access := ctx.form['push_access'].int()
	merge_access := ctx.form['merge_access'].int()
	app.protect_branch(repo.id, pattern, push_access, merge_access) or {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'invalid or duplicate protected branch rule'
		})
	}
	return ctx.json(ApiProtectedBranchView{
		id:           db_last_insert_id(mut app.db)
		pattern:      pattern
		push_access:  push_access
		merge_access: merge_access
	})
}

@['/api/v1/repos/:username/:repo_name/protected-branches/:id'; post]
pub fn (mut app App) api_v1_update_protected_branch(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	rule := app.find_protected_branch_by_id(repo.id, id.int()) or { return ctx.api_not_found() }
	push_access := ctx.form['push_access'].int()
	merge_access := ctx.form['merge_access'].int()
	app.update_protected_branch(repo.id, rule.id, push_access, merge_access) or {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'invalid protected branch access level'
		})
	}
	return ctx.json(ApiProtectedBranchView{
		id:           rule.id
		pattern:      rule.pattern
		push_access:  push_access
		merge_access: merge_access
	})
}

@['/api/v1/repos/:username/:repo_name/protected-branches/:id/delete'; post]
pub fn (mut app App) api_v1_delete_protected_branch(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	rule := app.find_protected_branch_by_id(repo.id, id.int()) or { return ctx.api_not_found() }
	app.unprotect_branch(repo.id, rule.id) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to remove protected branch rule'
		})
	}
	return ctx.json({
		'success': 'true'
	})
}

@['/api/v1/repos/:username/:repo_name/approval-rule'; post]
pub fn (mut app App) api_v1_update_approval_rule(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if app.repo_access_level(user.id, repo) < project_access_maintainer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'Maintainer access is required'
		})
	}
	required := ctx.form['required'].int()
	app.set_repo_required_approvals(repo.id, required) or {
		ctx.send_custom_error(400, 'Bad Request')
		return ctx.json({
			'success': 'false'
			'message': 'required approvals must be between 0 and 100'
		})
	}
	return ctx.json({
		'required_approvals': required.str()
	})
}

@['/api/v1/repos/:username/:repo_name/pulls/:id/approvals']
pub fn (mut app App) api_v1_pull_approvals(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.api_not_found() }
	if pr.repo_id != repo.id {
		return ctx.api_not_found()
	}
	approvals := app.find_pull_request_approvals(pr.id)
	mut approved_by := []ApiApprovalView{cap: approvals.len}
	for item in approvals {
		approved_by << ApiApprovalView{
			user_id:    item.user.id
			username:   item.user.username
			created_at: item.approval.created_at
		}
	}
	return ctx.json(ApiApprovalStatusView{
		count:       approvals.len
		required:    repo.required_approvals
		satisfied:   approvals.len >= repo.required_approvals
		approved_by: approved_by
	})
}

@['/api/v1/repos/:username/:repo_name/pulls/:id/approve'; post]
pub fn (mut app App) api_v1_approve_pull(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.api_not_found() }
	if pr.repo_id != repo.id || !pr.is_open() || pr.author_id == user.id
		|| app.repo_access_level(user.id, repo) < project_access_developer {
		ctx.send_custom_error(403, 'Forbidden')
		return ctx.json({
			'success': 'false'
			'message': 'eligible Developer access is required'
		})
	}
	app.approve_pull_request(pr.id, user.id) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to approve merge request'
		})
	}
	return app.api_v1_pull_approvals(mut ctx, username, repo_name, id)
}

@['/api/v1/repos/:username/:repo_name/pulls/:id/revoke-approval'; post]
pub fn (mut app App) api_v1_revoke_pull_approval(mut ctx Context, username string, repo_name string, id string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.api_not_found() }
	if pr.repo_id != repo.id {
		return ctx.api_not_found()
	}
	app.revoke_pull_request_approval(pr.id, user.id) or {
		ctx.send_custom_error(500, 'Internal Server Error')
		return ctx.json({
			'success': 'false'
			'message': 'failed to revoke approval'
		})
	}
	return app.api_v1_pull_approvals(mut ctx, username, repo_name, id)
}
