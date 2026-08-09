module main

fn test_english_count_uses_plural_for_twenty_one() {
	forms := ['issue', 'issues', 'issues']

	assert pick_plural_form(1, forms, .en) == 'issue'
	assert pick_plural_form(21, forms, .en) == 'issues'
	assert pick_plural_form(121, forms, .en) == 'issues'
}

fn test_russian_count_keeps_three_form_plural_rules() {
	forms := ['one', 'few', 'many']

	assert pick_plural_form(1, forms, .ru) == 'one'
	assert pick_plural_form(2, forms, .ru) == 'few'
	assert pick_plural_form(5, forms, .ru) == 'many'
	assert pick_plural_form(11, forms, .ru) == 'many'
	assert pick_plural_form(21, forms, .ru) == 'one'
}
