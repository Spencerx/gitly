const registerForm = document.getElementById("register-form");
const registerError = document.getElementById("register-error");
const registerSubmit = registerForm.querySelector("input[type=submit]");

function showRegisterError(msg) {
  registerError.textContent = msg;
  registerError.classList.add("alert");
  registerError.style.display = "";
}

function clearRegisterError() {
  registerError.textContent = "";
  registerError.classList.remove("alert");
}

registerError.addEventListener("click", clearRegisterError);

registerForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  registerSubmit.disabled = true;
  clearRegisterError();

  const data = new FormData(registerForm);
  data.set("no_redirect", "1");

  let response;
  try {
    response = await fetch(registerForm.action, {
      method: "POST",
      body: data,
    });
  } catch (err) {
    showRegisterError("Network error: " + err.message);
    registerSubmit.disabled = false;
    return;
  }

  const body = (await response.text()).trim();

	if (response.ok && body === "ok") {
		const username = String(data.get("username") || "").trim().toLowerCase();
		window.location.href = "/" + encodeURIComponent(username);
		return;
	}

  showRegisterError(body || "Failed to register");
  registerSubmit.disabled = false;
});
