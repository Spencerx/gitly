module main

import os

const default_avatar_name = 'default_avatar.png'
const assets_path = 'assets'
const avatar_max_file_size = 1 * 1024 * 1024 // 1 megabyte

const supported_mime_types = [
	'image/jpeg',
	'image/png',
	'image/webp',
]

fn validate_avatar_content_type(content_type string) bool {
	return supported_mime_types.contains(content_type)
}

fn extract_file_extension_from_mime_type(mime_type string) !string {
	is_valid_mime_type := validate_avatar_content_type(mime_type)

	if !is_valid_mime_type {
		return error('MIME type is not supported')
	}

	mime_parts := mime_type.split('/')

	return mime_parts[1]
}

fn validate_avatar_file_size(content string) bool {
	return content.len > 0 && content.len <= avatar_max_file_size
}

fn validate_avatar_content(content_type string, content string) bool {
	bytes := content.bytes()
	return match content_type {
		'image/png' {
			bytes.len >= 8 && bytes[..8] == [u8(0x89), `P`, `N`, `G`, `\r`, `\n`, u8(0x1a), `\n`]
		}
		'image/jpeg' {
			bytes.len >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff
		}
		'image/webp' {
			bytes.len >= 12 && bytes[..4].bytestr() == 'RIFF' && bytes[8..12].bytestr() == 'WEBP'
		}
		else {
			false
		}
	}
}

fn (app App) build_avatar_file_path(avatar_filename string) string {
	relative_path := os.join_path(app.config.avatars_path, avatar_filename)

	return os.abs_path(relative_path)
}

fn (app App) build_avatar_file_url(avatar_filename string) string {
	return os.join_path('/avatars', avatar_filename)
}

fn (app App) write_user_avatar(avatar_filename string, file_content string) bool {
	path := os.join_path(app.config.avatars_path, avatar_filename)

	os.write_file(path, file_content) or { return false }

	return true
}

fn (app App) prepare_user_avatar_url(avatar_filename_or_url string) string {
	is_url := avatar_filename_or_url.starts_with('http')
	is_default_avatar := avatar_filename_or_url == default_avatar_name
	if is_url {
		return avatar_filename_or_url
	}
	if is_default_avatar {
		return os.join_path('/', assets_path, avatar_filename_or_url)
	}
	return app.build_avatar_file_url(avatar_filename_or_url)
}
