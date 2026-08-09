module main

import veb
import regex

const max_search_query_len = 100

@['/search']
pub fn (mut app App) search() veb.Result {
	query := (ctx.query['query'] or { '' }).trim_space()
	requested_type := ctx.query['type'] or { 'repos' }
	search_type := if requested_type in ['repos', 'users'] { requested_type } else { 'repos' }
	sanitize_query := r'[A-Za-z0-9]+'
	mut re := regex.regex_opt(sanitize_query) or { panic(err) }

	bounded_query := if query.len > max_search_query_len {
		query[..max_search_query_len]
	} else {
		query
	}
	valid_query := re.find_all_str(bounded_query).join(' ')

	repos := if search_type == 'repos' && valid_query != '' {
		app.search_public_repos(valid_query)
	} else {
		[]Repo{}
	}

	users := if search_type == 'users' && valid_query != '' {
		app.search_users(valid_query)
	} else {
		[]User{}
	}

	return $veb.html()
}
