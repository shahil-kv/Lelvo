// Applies the saved theme before the page draws, so dark mode doesn't flash light. Light is the default;
// the toggle in the header (app.js) saves the choice. A separate file because the CSP blocks inline scripts.
(() => {
  let theme = "light";
  try { if (localStorage.getItem("lelvo-theme") === "dark") theme = "dark"; } catch {}
  document.documentElement.dataset.theme = theme;
})();
