module main

import veb

struct LangStat {
	id          int    @[primary; sql: serial]
	repo_id     int    @[unique: 'langstat']
	name        string @[unique: 'langstat']
	lines_count int
	pct         int // out of 1000
	color       string
}

const min_lang_summary_pct = 5 // pct is stored in tenths of a percent, so 5 is 0.5%.

fn (app App) add_lang_stat(lang_stat LangStat) ! {
	sql app.db {
		insert lang_stat into LangStat
	}!
}

pub fn (l &LangStat) pct_html() veb.RawHtml {
	x := f64(l.pct) / 10.0
	sloc := if l.lines_count < 1000 {
		l.lines_count.str()
	} else {
		(l.lines_count / 1000).str() + 'k'
	}

	return '<span>${x}%</span> <span class=lang-stat-loc>${sloc} loc</span>'
}

pub fn (app App) find_repo_lang_stats(repo_id int) []LangStat {
	stats := sql app.db {
		select from LangStat where repo_id == repo_id order by pct desc
	} or { return []LangStat{} }
	return stats.filter(it.pct >= min_lang_summary_pct)
}

fn (app App) remove_repo_lang_stats(repo_id int) ! {
	sql app.db {
		delete from LangStat where repo_id == repo_id
	}!
}
