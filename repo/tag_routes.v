module main

import veb
import os

@['/:username/:repo_name/tag/:tag/:format']
pub fn (mut app App) handle_download_tag_archive(username string, repo_name string, tag string, format string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	if !is_safe_ref(tag) || format !in ['zip', 'tar.gz'] {
		return ctx.not_found()
	}

	archive_abs_path := os.abs_path(app.config.archive_path)
	snapshot_format := format
	safe_tag_name := tag.replace('/', '-')
	snapshot_name := '${username}_${repo_name}_${safe_tag_name}.${snapshot_format}'
	archive_path := '${archive_abs_path}/${snapshot_name}'

	if format == 'zip' {
		repo.archive_tag(tag, archive_path, .zip)
	} else {
		repo.archive_tag(tag, archive_path, .tar)
	}

	archive_content := os.read_file(archive_path) or { return ctx.not_found() }

	return app.send_file(mut ctx, snapshot_name, archive_content)
}
