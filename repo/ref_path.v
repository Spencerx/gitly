module main

import git

// RepoRefPath is the result of splitting a repository browsing URL into an
// existing Git ref and the path below that ref. Git refs can contain `/`, so a
// route cannot safely assume that the first URL segment is the whole ref.
struct RepoRefPath {
	ref_name string
	path     string
}

// browsable_ref_names maps accepted URL spellings to an unambiguous Git
// revision. Branches retain their short name because that is also the cache
// key used throughout Gitly. Tags use their fully-qualified ref so a branch
// and tag with the same short name can never be resolved by Git's DWIM rules.
// A short ambiguous spelling deliberately selects the branch; callers can
// select the tag explicitly through `refs/tags/<name>`.
fn (repo Repo) browsable_ref_names() (map[string]string, int) {
	result := git.Git.exec_in_dir(repo.git_dir, ['for-each-ref', '--format=%(refname)', 'refs/heads/',
		'refs/tags/'])
	if result.exit_code != 0 {
		return map[string]string{}, 0
	}

	mut refs := map[string]string{}
	mut tag_names := []string{}
	mut ref_count := 0
	for line in result.output.split_into_lines() {
		full_name := line.trim_space()
		if full_name.starts_with('refs/heads/') {
			name := full_name.trim_string_left('refs/heads/')
			if is_safe_ref(name) {
				refs[name] = name
				refs[full_name] = name
				ref_count++
			}
		} else if full_name.starts_with('refs/tags/') {
			name := full_name.trim_string_left('refs/tags/')
			if is_safe_ref(name) {
				tag_names << name
				ref_count++
			}
		}
	}
	// Apply tags after collecting heads so explicit refs/tags/* always means a
	// tag, while the short spelling is installed only when no branch owns it.
	for name in tag_names {
		full_name := 'refs/tags/${name}'
		refs[full_name] = full_name
		if name !in refs {
			refs[name] = full_name
		}
	}
	return refs, ref_count
}

fn (repo Repo) contains_commit_object(hash string) bool {
	if !is_valid_commit_hash(hash) {
		return false
	}
	result := git.Git.exec_in_dir(repo.git_dir, ['rev-parse', '--verify', '--quiet',
		'${hash}^{commit}'])
	return result.exit_code == 0
}

// resolve_repo_ref_path resolves the longest prefix of a browsing route that
// is an actual branch, tag, or commit. Longest-prefix resolution makes
// `feature/api/src/main.v` select branch `feature/api` when it exists, while
// still allowing branch `feature` to browse `api/src/main.v` when it does not.
// A blob/raw/edit route sets require_path so that a ref without a file cannot
// accidentally be rendered as a file page.
fn resolve_repo_ref_path(repo Repo, location string, require_path bool) ?RepoRefPath {
	if location == '' || location.len > 4352 || location.starts_with('/') || location.ends_with('/')
		|| location.contains('//') {
		return none
	}

	parts := location.split('/')
	if parts.len == 0 || (require_path && parts.len < 2) {
		return none
	}
	refs, ref_count := repo.browsable_ref_names()
	max_ref_parts := if require_path { parts.len - 1 } else { parts.len }
	for ref_parts := max_ref_parts; ref_parts >= 1; ref_parts-- {
		ref_name := parts[..ref_parts].join('/')
		if !is_safe_ref(ref_name) {
			continue
		}
		path := if ref_parts < parts.len { parts[ref_parts..].join('/') } else { '' }
		if path != '' && !is_valid_repo_file_path(path) {
			continue
		}
		if ref_name in refs {
			return RepoRefPath{
				ref_name: refs[ref_name]
				path:     path
			}
		}
		if repo.contains_commit_object(ref_name) {
			return RepoRefPath{
				ref_name: ref_name
				path:     path
			}
		}
	}

	// A new repository has a symbolic HEAD but no branch ref until its first
	// push. Preserve its empty default-branch tree without accepting arbitrary
	// paths or unknown refs.
	if !require_path && parts.len == 1 && ref_count == 0 && location == repo.primary_branch
		&& is_safe_ref(location) {
		return RepoRefPath{
			ref_name: location
		}
	}
	return none
}
