// Lelvo website: theme, menu, download buttons, the hero, the feature tour, the security demo and the FAQ.
// Everything here is an enhancement: without JavaScript the page is complete and readable.
(() => {
  const root = document.documentElement;
  root.classList.add("js");
  const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Theme toggle: light by default, the choice kept for the next visit (an inline head script applies it on load).
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

  // Header gets its rule once the page has moved.
  const header = document.querySelector(".site-header");
  const onScroll = () => header?.classList.toggle("is-scrolled", window.scrollY > 8);
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Menu on narrow screens: closes on a link, on Escape and on a tap outside.
  const menu = document.querySelector(".menu-btn");
  const setMenu = (open) => {
    header?.classList.toggle("is-open", open);
    menu?.setAttribute("aria-expanded", String(open));
    menu?.setAttribute("aria-label", open ? "Close menu" : "Menu");
  };
  menu?.addEventListener("click", () => setMenu(!header.classList.contains("is-open")));
  document.querySelectorAll(".mobile-nav a").forEach((a) => a.addEventListener("click", () => setMenu(false)));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && header?.classList.contains("is-open")) { setMenu(false); menu.focus(); }
  });
  document.addEventListener("click", (e) => {
    if (header?.classList.contains("is-open") && !header.contains(e.target)) setMenu(false);
  });

  // The download section puts the visitor's own device first and outlines it. iPadOS reports itself as a Mac.
  const ua = navigator.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const platform = ios ? "ios" : /Android/.test(ua) ? "android" : /Macintosh/.test(ua) ? "mac" : "";
  const card = platform && document.querySelector(`.platform[data-platform="${platform}"]`);
  if (card) {
    card.classList.add("is-mine");
    if (platform !== "mac") card.parentElement.prepend(card);
  }

  // Sections rise in once as they arrive.
  const revealed = [...document.querySelectorAll("[data-reveal], .band")];
  if ("IntersectionObserver" in window && !calm) {
    const reveal = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      e.target.classList.add("is-in");
      reveal.unobserve(e.target);
    }), { rootMargin: "0px 0px -8% 0px" });
    revealed.forEach((el) => reveal.observe(el));
  } else {
    revealed.forEach((el) => el.classList.add("is-in"));
  }

  // Feature tour. Wide screens: a list beside one phone; picking a feature shows its screen, and while nobody has
  // picked one it advances every 6 s (paused on hover, off screen, or with reduced motion). Narrow screens: swipe cards.
  const tour = document.querySelector(".tour");
  const steps = [...document.querySelectorAll(".tour-step")];
  if (tour && steps.length) {
    const shots = [...tour.querySelectorAll(".tour-phone img")];
    const caption = tour.querySelector(".tour-caption");
    const dots = [...tour.querySelectorAll(".tour-dots span")];
    const row = tour.querySelector(".tour-steps");
    const wide = window.matchMedia("(min-width: 1001px)");
    let current = 0, timer = 0, picked = false, inView = false, hovering = false;

    const show = (i) => {
      current = i;
      steps.forEach((s, j) => {
        s.classList.toggle("is-active", j === i);
        s.querySelector(".tour-pick")?.setAttribute("aria-pressed", String(j === i));
      });
      shots.forEach((img) => img.classList.toggle("is-on", img.dataset.shot === steps[i].dataset.shot));
      if (caption) caption.textContent = steps[i].querySelector(".note")?.textContent ?? "";
    };
    const schedule = () => {
      clearTimeout(timer);
      const play = wide.matches && !calm && !picked && inView && !hovering && !document.hidden;
      tour.classList.toggle("is-playing", play);
      if (play) timer = setTimeout(() => { show((current + 1) % steps.length); schedule(); }, 6000);
    };
    const pickStep = (i) => { picked = true; show(i); schedule(); };
    const setMode = () => {
      steps.forEach((s, i) => {
        // A real button inside the heading, not role="button" on the card, which would hide the heading from screen readers.
        const h = s.querySelector("h3"), pick = h.querySelector(".tour-pick");
        if (wide.matches && !pick) {
          const b = document.createElement("button");
          b.type = "button"; b.className = "tour-pick"; b.textContent = h.textContent;
          b.setAttribute("aria-pressed", String(i === current));
          h.replaceChildren(b);
        } else if (!wide.matches && pick) h.textContent = pick.textContent;
      });
      if (wide.matches) { row.removeAttribute("tabindex"); row.removeAttribute("aria-label"); }
      else { row.tabIndex = 0; row.setAttribute("aria-label", "Features, scroll sideways for more"); }
      schedule();
    };

    steps.forEach((s, i) => {
      // The whole card takes clicks; the heading button gives keyboard and screen reader access, and its clicks bubble here.
      s.addEventListener("click", () => { if (wide.matches) pickStep(i); });
    });
    tour.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") { hovering = true; schedule(); } });
    tour.addEventListener("pointerleave", () => { hovering = false; schedule(); });
    document.addEventListener("visibilitychange", schedule);
    wide.addEventListener("change", setMode);
    if ("IntersectionObserver" in window) {
      new IntersectionObserver((entries) => { inView = entries[0].isIntersecting; schedule(); }, { threshold: 0.35 }).observe(tour);
      const swipe = new IntersectionObserver((entries) => entries.forEach((e) => {
        if (e.intersectionRatio < 0.6) return;
        const i = steps.indexOf(e.target);
        dots.forEach((d, j) => d.classList.toggle("is-on", j === i));
      }), { root: row, threshold: [0.6] });
      steps.forEach((s) => swipe.observe(s));
    }
    show(0);
    setMode();
  }

  // On phones the details are a sideways row too; make it reachable by keyboard there.
  const details = document.querySelector(".grid-details");
  const phone = window.matchMedia("(max-width: 640px)");
  const detailsMode = () => {
    if (!details) return;
    if (phone.matches) { details.tabIndex = 0; details.setAttribute("aria-label", "Details, scroll sideways for more"); }
    else { details.removeAttribute("tabindex"); details.removeAttribute("aria-label"); }
  };
  phone.addEventListener("change", detailsMode);
  detailsMode();

  // Security: the same library seen two ways, and a photo travelling from the phone to the channel.
  const vault = document.querySelector(".vault");
  if (vault) {
    const tabs = [...vault.querySelectorAll(".vault-tab")];
    const select = (tab, focus) => {
      tabs.forEach((t) => {
        const on = t === tab;
        t.classList.toggle("is-on", on);
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).classList.toggle("is-off", !on);
      });
      if (focus) tab.focus();
    };
    tabs.forEach((t, i) => {
      t.addEventListener("click", () => select(t));
      t.addEventListener("keydown", (e) => {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        e.preventDefault();
        select(tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length], true);
      });
    });

    // A photo leaves the phone, locks before it moves, skips the server that doesn't exist and lands in the channel
    // as a new scrambled file. Every run shows different ciphertext, as real encryption would. Runs only while in view.
    const track = vault.querySelector(".track");
    const packet = vault.querySelector(".packet");
    const lockEl = vault.querySelector(".packet-lock");
    const phoneStop = vault.querySelector(".stop-phone");
    const channelStop = vault.querySelector(".stop-channel");
    const newest = vault.querySelector(".file");
    const cipher = newest?.querySelector(".file-cipher");
    const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const noise = () => {
      const bytes = crypto.getRandomValues(new Uint8Array(46));
      return "CG1E:" + Array.from(bytes, (b) => b64[b & 63]).join("") + "…";
    };
    const hit = (el) => { el.classList.add("is-hit"); setTimeout(() => el.classList.remove("is-hit"), 320); };
    let loop = 0;
    const run = () => {
      const travel = track.clientWidth - packet.offsetWidth;
      const timing = { duration: 2600, fill: "both" };
      hit(phoneStop);
      packet.animate([
        { transform: "translateX(0) scale(0.6)", opacity: 0 },
        { transform: "translateX(0) scale(1)", opacity: 1, offset: 0.12 },
        { transform: "translateX(0) scale(1)", opacity: 1, offset: 0.32 },
        { transform: `translateX(${travel}px) scale(1)`, opacity: 1, offset: 0.88 },
        { transform: `translateX(${travel}px) scale(0.55)`, opacity: 0 },
      ], { ...timing, easing: "cubic-bezier(0.45, 0, 0.2, 1)" }).onfinish = () => {
        hit(channelStop);
        if (cipher) cipher.textContent = noise();
        newest.classList.remove("is-landed");
        void newest.offsetWidth; // restart the highlight
        newest.classList.add("is-landed");
      };
      lockEl.animate([{ opacity: 0 }, { opacity: 0, offset: 0.14 }, { opacity: 1, offset: 0.28 }, { opacity: 1 }], timing);
    };
    if (!calm && "IntersectionObserver" in window && packet.animate) {
      new IntersectionObserver((entries) => {
        clearInterval(loop);
        if (!entries[0].isIntersecting) return;
        run();
        loop = setInterval(() => { if (!document.hidden) run(); }, 5200);
      }, { threshold: 0.5 }).observe(vault);
    }
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
        answer.animate([{ height: `${h}px`, opacity: 1 }, { height: "0px", opacity: 0 }], { duration: 240, easing: "ease-in" })
          .onfinish = () => { d.open = false; };
      } else {
        d.open = true;
        const h = answer.offsetHeight;
        answer.animate([{ height: "0px", opacity: 0 }, { height: `${h}px`, opacity: 1 }], { duration: 320, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
      }
    });
  });

  // Hero: three photos lift off the phone, lock, and land in the channel, whose count rolls up. Plays once, when the
  // stage is in view; transform and opacity only. With reduced motion the card simply shows the finished state.
  const stage = document.querySelector(".stage");
  const shot = stage?.querySelector(".hero-shot");
  const avatar = stage?.querySelector(".channel-avatar");
  const countEl = stage?.querySelector("[data-count]");
  const status = stage?.querySelector(".status");
  if (stage && shot && avatar && countEl && status) {
    const fmt = new Intl.NumberFormat("en");
    const end = Number(countEl.dataset.count);
    const cells = [[0, 400], [305, 400], [458, 400]]; // grid cells, in pixels of the 607 px wide screenshot
    const lock = '<svg viewBox="0 0 24 24"><rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V8a4 4 0 018 0v2.5"/></svg>';
    const finish = () => { countEl.textContent = fmt.format(end); status.classList.add("is-on"); };
    const play = () => {
      let count = end - cells.length;
      countEl.textContent = fmt.format(count);
      const s = stage.getBoundingClientRect(), r = shot.getBoundingClientRect(), a = avatar.getBoundingClientRect();
      const k = r.width / 607, size = 150 * k;
      cells.forEach(([x, y], i) => {
        const tile = document.createElement("div");
        tile.className = "tile";
        tile.setAttribute("aria-hidden", "true");
        tile.innerHTML = `<i>${lock}</i>`;
        Object.assign(tile.style, {
          width: `${size}px`, height: `${size}px`, backgroundImage: `url("${shot.currentSrc || shot.src}")`,
          backgroundSize: `${607 * k}px auto`, backgroundPosition: `${-x * k}px ${-y * k}px`,
        });
        stage.appendChild(tile);
        const sx = r.left - s.left + x * k, sy = r.top - s.top + y * k;
        const ex = a.left - s.left + a.width / 2 - size / 2, ey = a.top - s.top + a.height / 2 - size / 2;
        const mx = (sx + ex) / 2 + 10, my = Math.min(sy, ey) - 40;
        const timing = { duration: 1250, delay: 400 + i * 420, fill: "both" };
        tile.animate([
          { transform: `translate(${sx}px, ${sy}px) scale(1)`, opacity: 0 },
          { transform: `translate(${sx}px, ${sy - 6}px) scale(1.06)`, opacity: 1, offset: 0.18 },
          { transform: `translate(${mx}px, ${my}px) scale(0.8)`, opacity: 1, offset: 0.6 },
          { transform: `translate(${ex}px, ${ey}px) scale(0.3)`, opacity: 0 },
        ], { ...timing, easing: "cubic-bezier(0.45, 0, 0.2, 1)" }).onfinish = () => {
          tile.remove();
          countEl.textContent = fmt.format(++count);
          avatar.classList.add("is-hit");
          setTimeout(() => avatar.classList.remove("is-hit"), 180);
          if (count === end) status.classList.add("is-on");
        };
        tile.firstChild.animate([{ opacity: 0 }, { opacity: 0, offset: 0.3 }, { opacity: 1, offset: 0.5 }, { opacity: 1 }], timing);
      });
    };
    if (calm || !("IntersectionObserver" in window) || !Element.prototype.animate) {
      finish();
    } else {
      countEl.textContent = fmt.format(end - cells.length);
      const seen = new IntersectionObserver((entries) => {
        if (entries[0].intersectionRatio < 0.6) return;
        seen.disconnect();
        play();
      }, { threshold: [0.6] });
      const start = () => seen.observe(stage);
      if (shot.complete) start(); else shot.addEventListener("load", start, { once: true });
    }
  }
})();
