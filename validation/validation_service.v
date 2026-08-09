module validation

import regex

pub fn is_username_valid(value string) bool {
	query := r'^[A-Za-z][A-Za-z0-9_\.\-]{1,39}$'

	mut re := regex.regex_opt(query) or { panic(err) }

	return re.matches_string(value)
}

pub fn is_email_valid(value string) bool {
	if value.len > 254 {
		return false
	}
	query := r'^[^\s@]+@[^\s@]+\.[^\s@]+$'
	mut re := regex.regex_opt(query) or { panic(err) }
	return re.matches_string(value)
}

pub fn is_repository_name_valid(value string) bool {
	query := r'^[A-Za-z][A-Za-z0-9_\.\-]{0,100}$'

	mut re := regex.regex_opt(query) or { panic(err) }

	return re.matches_string(value)
}

pub fn is_string_empty(value string) bool {
	trimmed := value.trim(' ')

	return trimmed == ''
}
