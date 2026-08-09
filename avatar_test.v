module main

import config

fn test_extract_file_extension_from_mime_type() {
	extension := extract_file_extension_from_mime_type('image/png') or { '' }

	assert extension == 'png'
}

fn test_avatar_content_must_match_declared_type() {
	png := [u8(0x89), `P`, `N`, `G`, `\r`, `\n`, u8(0x1a), `\n`, u8(0)].bytestr()
	jpeg := [u8(0xff), u8(0xd8), u8(0xff), u8(0xe0)].bytestr()
	webp := 'RIFF\x00\x00\x00\x00WEBP'

	assert validate_avatar_content('image/png', png)
	assert validate_avatar_content('image/jpeg', jpeg)
	assert validate_avatar_content('image/webp', webp)
	assert !validate_avatar_content('image/png', '<script>alert(1)</script>')
	assert !validate_avatar_content('image/jpeg', png)
	assert !validate_avatar_content('image/webp', 'RIFFnot-an-image')
}

fn test_avatar_size_rejects_empty_and_oversized_files() {
	assert !validate_avatar_file_size('')
	assert validate_avatar_file_size('small')
	assert !validate_avatar_file_size('x'.repeat(avatar_max_file_size + 1))
}

fn test_avatar_url_does_not_expose_storage_path() {
	app := App{
		config: config.Config{
			avatars_path: '/srv/private/gitly/avatars'
		}
	}
	assert app.build_avatar_file_url('alice.png') == '/avatars/alice.png'
}
