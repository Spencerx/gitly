module git

import os

fn test_exec_in_dir_with_env_drains_large_stderr_and_keeps_environment() {
	$if !windows {
		result := Git.exec_in_dir_with_env(os.temp_dir(), [
			'-c',
			r'alias.noisy=!printf "%070000d" 0 >&2; printf "$GITLY_TEST_ENV"',
			'noisy',
		], {
			'GITLY_TEST_ENV': 'env-ok'
		})
		assert result.exit_code == 0
		assert result.output.len == 70_006
		assert result.output.ends_with('env-ok')
	}
}
