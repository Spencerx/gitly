module main

import veb

@['/settings/security']
fn (mut app App) security() veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	logs := app.get_all_user_security_logs(ctx.user.id)

	return $veb.html()
}
