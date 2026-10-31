// Lelvo website: theme toggle, smooth scrolling, the feature tour, the FAQ and the waiting list.
// Everything here is an enhancement: without JavaScript the page is complete and readable.
(() => {
  const root = document.documentElement;
  root.classList.add("js");
  const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Theme toggle: light by default, the choice kept for the next visit (theme.js applies it on load).
  const toggle = document.querySelector(".theme-toggle");
  const themeColor = document.querySelector('meta[name="theme-color"]');
  const showTheme = () => {
    const dark = root.dataset.theme === "dark";
    if (toggle) toggle.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme");
    if (themeColor) themeColor.content = getComputedStyle(root).getPropertyValue("--paper").trim();
  };
  toggle?.addEventListener("click", () => {
    root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
    try { localStorage.setItem("lelvo-theme", root.dataset.theme); } catch {}
    showTheme();
  });
  showTheme();

  // Smooth, inertial scrolling (Lenis), also for in-page links. Off when the person asks for less motion.
  let lenis = null;
  if (!calm && window.Lenis) {
    lenis = new window.Lenis({ autoRaf: true, anchors: { offset: -72 }, lerp: 0.11 });
  }

  // Header gets its rule once the page has moved.
  const header = document.querySelector(".site-header");
  const onScroll = () => header?.classList.toggle("is-scrolled", window.scrollY > 8);
  if (lenis) lenis.on("scroll", onScroll); else window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Feature tour: the step in the middle of the screen picks the phone's screen.
  const steps = [...document.querySelectorAll(".tour-step")];
  const shots = [...document.querySelectorAll(".tour-phone img")];
  if ("IntersectionObserver" in window && steps.length) {
    const pick = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        steps.forEach((s) => s.classList.toggle("is-active", s === e.target));
        shots.forEach((img) => img.classList.toggle("is-on", img.dataset.shot === e.target.dataset.shot));
      });
    }, { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((s) => pick.observe(s));
    steps[0].classList.add("is-active");
  }

  // FAQ: answers slide open and closed instead of jumping.
  document.querySelectorAll(".faq details").forEach((d) => {
    const summary = d.querySelector("summary");
    const answer = d.querySelector(".answer");
    summary.addEventListener("click", (event) => {
      if (calm || !answer.animate) return;
      event.preventDefault();
      if (d.open) {
        const h = answer.offsetHeight;
        answer.animate([{ height: `${h}px`, opacity: 1 }, { height: "0px", opacity: 0 }], { duration: 260, easing: "ease-in" })
          .onfinish = () => { d.open = false; };
      } else {
        d.open = true;
        const h = answer.offsetHeight;
        answer.animate([{ height: "0px", opacity: 0 }, { height: `${h}px`, opacity: 1 }], { duration: 340, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
      }
    });
  });

  // Waiting list: posts to a Google Apps Script that adds a row to a Sheet (Scripts/waitlist.gs).
  // Apps Script answers through a redirect without CORS headers, so the reply can't be read: a request that
  // reaches Google counts as joined, and the script itself ignores duplicates.
  const waitlist = document.querySelector(".waitlist");
  if (waitlist && !waitlist.action.includes("PASTE_")) {
    const note = waitlist.querySelector(".waitlist-note");
    const button = waitlist.querySelector("button");
    const email = waitlist.querySelector('input[type="email"]');
    waitlist.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!email.checkValidity()) {
        note.textContent = "Enter your email address, like you@example.com.";
        email.focus();
        return;
      }
      button.disabled = true;
      try {
        await fetch(waitlist.action, { method: "POST", mode: "no-cors", body: new URLSearchParams(new FormData(waitlist)) });
        waitlist.classList.add("is-done");
        note.textContent = "You're on the list. We'll email you once, when Lelvo is on TestFlight.";
      } catch {
        note.textContent = "That didn't go through. Check your connection and try again.";
        button.disabled = false;
      }
    });
  }
})();
