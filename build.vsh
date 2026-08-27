import os

path := 'static/css/gitly.css'
source := 'static/css/gitly.scss'
if sassc := os.find_abs_path_of_executable('sassc') {
	result := os.exec([sassc, source])
	if result.exit_code != 0 {
		eprintln('Could not compile ${source}: ${result.output}')
		exit(1)
	}
	// Write only after sassc succeeds, so a compiler failure cannot truncate a
	// previously usable stylesheet.
	os.write_file(path, result.output)!
} else if !os.exists(path) || os.file_size(path) == 0 {
	eprintln('sassc is required to compile ${source}; refusing to download unpinned build output')
	exit(1)
} else {
	eprintln('sassc was not found; using the existing ${path}')
}

ret := system('v .')
if ret == 0 {
	println('Gitly has been successfully built, run it with ./gitly')
}
