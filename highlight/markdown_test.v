module highlight

const markdown = '<script>  alert(true) </script> <!--  comment -->test'
const html = '<p>test</p>'

fn test_convert_markdown_to_html() {
	assert convert_markdown_to_html(markdown) == html
}

fn test_convert_markdown_table_to_html() {
	markdown_table := '| V full version | V 0.5.1 |\n|:----------------|:--------|\n| OS | linux |\n'
	rendered := convert_markdown_to_html(markdown_table)

	assert rendered.contains('<table>')
	assert rendered.contains('<thead>')
	assert rendered.contains('<th align="left">V full version</th>')
	assert rendered.contains('<td align="left">linux</td>')
}
