const formEl = document.querySelector("form");

if (formEl) {
	formEl.addEventListener("submit", () => {
		const submitEl = formEl.querySelector("input[type=submit], button[type=submit]");
		if (submitEl) {
			submitEl.disabled = true;
		}
	});
}
