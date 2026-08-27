// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import git

struct Tag {
	id      int @[primary; sql: serial]
	repo_id int @[unique: 'tag']
mut:
	name       string @[unique: 'tag']
	hash       string
	message    string
	user_id    int
	created_at int
}

fn (mut app App) fetch_tags(repo Repo) ! {
	format := '%(refname:lstrip=2)${log_field_separator}%(objectname)${log_field_separator}%(subject)${log_field_separator}%(if)%(taggeremail)%(then)%(taggeremail:trim)%(else)%(authoremail:trim)%(end)${log_field_separator}%(creatordate:rfc)'
	result := git.Git.exec_in_dir(repo.git_dir, ['tag', '--format=${format}'])
	if result.exit_code != 0 {
		return error('could not list repository tags: ${result.output}')
	}

	mut present := map[string]bool{}

	for tag_output in result.output.split_into_lines() {
		tag_parts := tag_output.split(log_field_separator)
		if tag_parts.len < 5 || tag_parts[0] == '' {
			app.warn('ignoring malformed tag metadata')
			continue
		}
		tag_name := tag_parts[0]
		present[tag_name] = true
		commit_hash := tag_parts[1]
		commit_message := tag_parts[2]
		author_email := tag_parts[3]
		commit_date := time.parse_rfc2822(tag_parts[4]) or {
			app.info('Error: ${err}')
			continue
		}

		user := app.get_user_by_email(author_email) or {
			User{
				username: author_email
			}
		}

		app.insert_tag_into_db(repo.id, tag_name, commit_hash, commit_message, user.id,
			int(commit_date.unix()))!
	}

	for existing in app.get_all_repo_tags(repo.id) {
		if existing.name in present {
			continue
		}
		app.delete_release_for_tag(repo.id, existing.id)!
		tag_id := existing.id
		repo_id := repo.id
		sql app.db {
			delete from Tag where id == tag_id && repo_id == repo_id
		}!
	}
}

fn (mut app App) insert_tag_into_db(repo_id int, tag_name string, commit_hash string, commit_message string, user_id int, date int) ! {
	tags := sql app.db {
		select from Tag where repo_id == repo_id && name == tag_name limit 1
	} or { []Tag{} }

	if tags.len != 0 {
		id := tags[0].id
		sql app.db {
			update Tag set hash = commit_hash, message = commit_message, user_id = user_id,
			created_at = date where id == id
		}!
		return
	}

	new_tag := Tag{
		repo_id:    repo_id
		name:       tag_name
		hash:       commit_hash
		message:    commit_message
		user_id:    user_id
		created_at: date
	}

	sql app.db {
		insert new_tag into Tag
	}!
}

fn (mut app App) get_all_repo_tags(repo_id int) []Tag {
	return sql app.db {
		select from Tag where repo_id == repo_id order by created_at desc
	} or { [] }
}
