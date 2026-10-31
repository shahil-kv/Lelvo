// Lelvo website: theme toggle, smooth scrolling, the hero library, the feature tour, the FAQ and the waiting list.
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

  // Hero: the photos on the phone are buttons. Tap one and it flies into the channel; left alone, the hero plays
  // itself. Cells are in the screenshot's own pixels (607 × 1320, four 150 px columns).
  const journey = document.querySelector(".journey");
  if (journey) {
    const W = 607, H = 1320, CELL = 150, COLS = [0, 153, 305, 457], ROWS = [247, 400, 553];
    const FILES = [["IMG_4041.HEIC", "3.1 MB"], ["IMG_4042.HEIC", "2.7 MB"], ["IMG_4043.HEIC", "3.6 MB"], ["IMG_4044.DNG", "49.5 MB"],
      ["IMG_4045.HEIC", "2.9 MB"], ["IMG_4046.MOV", "164 MB"], ["IMG_4047.HEIC", "3.3 MB"], ["IMG_4048.HEIC", "4.0 MB"],
      ["IMG_4036.HEIC", "3.0 MB"], ["IMG_4037.DNG", "51.7 MB"]];
    const hero = document.querySelector(".hero");
    const taps = journey.querySelector(".taps");
    const stack = journey.querySelector(".stack");
    const count = journey.querySelector(".count");
    const hint = journey.querySelector(".hint");
    const shot = journey.querySelector(".phone img").currentSrc || "img/timeline.webp";
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    let files = 1284, lastTap = 0, queue = Promise.resolve(), visible = true;

    // A crop of one cell of the screenshot, for a box of any shape (ratio = height / width).
    const crop = (el, i, ratio) => {
      const x = COLS[i % 4], y = ROWS[Math.floor(i / 4)], h = CELL * ratio;
      el.style.backgroundImage = `url(${shot})`;
      el.style.backgroundSize = `${(W / CELL) * 100}% auto`;
      el.style.backgroundPosition = `${(x / (W - CELL)) * 100}% ${((y + (CELL - h) / 2) / (H - h)) * 100}%`;
    };
    const message = (i, sent) => {
      const el = document.createElement("div");
      el.className = sent ? "msg is-sent" : "msg";
      el.innerHTML = `<div class="msg-pic"><span class="msg-progress"><i></i></span></div><div class="msg-meta"><b></b><span></span></div>
        <div class="msg-state"><span></span><svg viewBox="0 0 18 12" aria-hidden="true"><path d="M1 6.5l3.5 3.5L11 3M7 10l1 1 8-9"/></svg></div>`;
      crop(el.querySelector(".msg-pic"), i, 9 / 16);
      el.querySelector("b").textContent = FILES[i][0];
      el.querySelector(".msg-meta span").textContent = FILES[i][1];
      el.querySelector(".msg-state span").textContent = sent ? "Original, backed up" : "Uploading";
      return el;
    };

    // The channel starts with two photos already in it, so the resting state is complete.
    stack.append(message(8, true), message(9, true));
    const buttons = ROWS.slice(0, 2).flatMap((y, r) => COLS.map((x, c) => {
      const i = r * 4 + c, b = document.createElement("button");
      b.type = "button";
      b.className = "tap";
      b.setAttribute("aria-label", `Back up ${FILES[i][0]}`);
      Object.assign(b.style, { left: `${(x / W) * 100}%`, top: `${(y / H) * 100}%`, width: `${(CELL / W) * 100}%`, height: `${(CELL / H) * 100}%` });
      b.addEventListener("click", () => {
        if (b.classList.contains("is-done") || b.classList.contains("is-lifted")) return;
        lastTap = Date.now();
        hint.classList.add("is-gone");
        send(b, i);
      });
      taps.append(b);
      return b;
    }));
    hint.hidden = false;

    function fly(b, i) {
      if (calm) return Promise.resolve();
      const box = journey.getBoundingClientRect();
      const from = b.getBoundingClientRect();
      const to = stack.getBoundingClientRect();
      const size = from.width;
      const flyer = document.createElement("span");
      flyer.className = "flyer";
      Object.assign(flyer.style, { width: `${size}px`, height: `${size}px` });
      crop(flyer, i, 1);
      journey.append(flyer);
      const x0 = from.left - box.left, y0 = from.top - box.top;
      const x1 = to.right - box.left - size * 1.6, y1 = to.bottom - box.top - size * 1.8;
      const qx = (x0 + x1) / 2, qy = Math.min(y0, y1) - 70;
      const frames = Array.from({ length: 11 }, (_, k) => {
        const u = k / 10, a = (1 - u) * (1 - u), m = 2 * (1 - u) * u, d = u * u;
        return { transform: `translate(${a * x0 + m * qx + d * x1}px, ${a * y0 + m * qy + d * y1}px) scale(${1 + 0.4 * u})`, opacity: u > 0.85 ? 0 : 1, offset: u };
      });
      return flyer.animate(frames, { duration: 950, easing: "cubic-bezier(0.45, 0, 0.2, 1)" }).finished.then(() => flyer.remove());
    }

    async function arrive(i) {
      const el = message(i, false);
      stack.append(el);
      // New messages land at the bottom; the stack scrolls up so the newest is in view.
      const feed = stack.parentElement;
      const shift = Math.max(0, stack.scrollHeight - feed.clientHeight + 24);
      stack.style.transform = `translateY(${-shift}px)`;
      if (!calm) {
        await wait(450);
        await el.querySelector(".msg-progress i").animate([{ width: "0%" }, { width: "100%" }], { duration: 1200, easing: "cubic-bezier(0.3, 0, 0.3, 1)", fill: "forwards" }).finished;
      }
      el.classList.add("is-sent");
      el.querySelector(".msg-state span").textContent = "Original, backed up";
      files += 1;
      count.textContent = files.toLocaleString("en-US");
      while (stack.children.length > 6) {
        const gone = stack.firstElementChild.offsetHeight + 10;
        stack.firstElementChild.remove();
        stack.style.transition = "none";
        stack.style.transform = `translateY(${-(shift - gone)}px)`;
        stack.offsetHeight;
        stack.style.transition = "";
      }
    }

    function send(b, i) {
      queue = queue.then(async () => {
        b.classList.add("is-lifted");
        if (!calm) await wait(220);
        await fly(b, i);
        b.classList.remove("is-lifted");
        await arrive(i);
        b.classList.add("is-done");
      });
      return queue;
    }

    // Plays by itself while on screen, and steps aside for a few seconds after someone taps.
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(([e]) => { visible = e.isIntersecting; hero.classList.toggle("is-away", !visible); }).observe(hero);
    }
    if (!calm) {
      (async () => {
        await wait(1200);
        for (;;) {
          if (visible && !document.hidden && Date.now() - lastTap > 6000) {
            let next = buttons.findIndex((b) => !b.classList.contains("is-done"));
            if (next < 0) { buttons.forEach((b) => b.classList.remove("is-done")); next = 0; }
            await send(buttons[next], next);
          }
          await wait(1800);
        }
      })();
    }
  }

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
