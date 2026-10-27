// Memvo website: smooth scrolling, the hero animation, the feature tour, reveals and the FAQ.
// Everything here is an enhancement: without JavaScript the page is complete and readable.
(() => {
  const root = document.documentElement;
  root.classList.add("js");
  const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Smooth, inertial scrolling (Lenis), also for in-page links. Off when the person asks for less motion.
  let lenis = null;
  if (!calm && window.Lenis) {
    lenis = new window.Lenis({ autoRaf: true, anchors: { offset: -72 }, lerp: 0.11 });
  }

  // Header gets its rule once the page has moved.
  const header = document.querySelector(".site-header");
  const onScroll = () => {
    header.classList.toggle("is-scrolled", window.scrollY > 8);
    drift();
  };

  // River: two rows of photos drift in opposite directions with the scroll.
  const river = document.querySelector(".river");
  const rows = [...document.querySelectorAll(".river-row")];
  function drift() {
    if (calm || !river) return;
    const r = river.getBoundingClientRect();
    const progress = (window.innerHeight - r.top) / (window.innerHeight + r.height); // 0 → 1 while on screen
    if (progress < 0 || progress > 1) return;
    rows.forEach((row) => {
      const dir = Number(row.dataset.drift);
      row.style.transform = `translate3d(${dir * (progress - 0.5) * 220}px, 0, 0)`;
    });
  }
  if (lenis) lenis.on("scroll", onScroll); else window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Hero: cells lift out of the real timeline screenshot and upload into the channel, one after another.
  // Cell positions are in the screenshot's own pixels (607 × 1320, four 150 px columns).
  const stage = document.querySelector(".hero-stage");
  if (stage) {
    const W = 607, H = 1320, CELL = 150;
    const COLS = [0, 153, 305, 457], ROWS = [247, 400, 553, 775, 928];
    const queue = [
      [1, 3, "IMG_4021.HEIC", "3.6 MB"], [3, 3, "IMG_4028.HEIC", "2.4 MB"], [1, 0, "IMG_4030.HEIC", "4.1 MB"],
      [4, 3, "IMG_4031.MOV", "182 MB"], [0, 1, "IMG_4033.HEIC", "3.2 MB"], [4, 1, "IMG_4036.DNG", "51.7 MB"],
      [3, 3, "IMG_4038.HEIC", "2.9 MB"], [0, 3, "IMG_4040.HEIC", "3.3 MB"], [4, 2, "IMG_4041.HEIC", "2.6 MB"],
    ];
    const screen = stage.querySelector(".hero-phone img");
    const list = stage.querySelector(".files");
    const count = stage.querySelector(".count");
    const arc = stage.querySelector(".path");
    const arcLabel = stage.querySelector(".path-label");
    const crop = (el, c, r) => {
      el.style.setProperty("--x", `${(COLS[c] / (W - CELL)) * 100}%`);
      el.style.setProperty("--y", `${(ROWS[r] / (H - CELL)) * 100}%`);
    };
    const local = (rect, box) => ({ x: rect.left - box.left, y: rect.top - box.top, w: rect.width, h: rect.height });

    // The dotted path from the phone to the channel, with its label in the middle.
    function drawPath() {
      const box = stage.getBoundingClientRect();
      const p = local(screen.getBoundingClientRect(), box);
      const c = local(list.getBoundingClientRect(), box);
      const card = local(stage.querySelector(".channel").getBoundingClientRect(), box);
      if (window.innerWidth <= 960) { arc.classList.remove("is-drawn"); return; }
      const x0 = p.x + p.w + 10, y0 = p.y + p.h * 0.3, x1 = card.x - 10, y1 = c.y + 26;
      const mx = (x0 + x1) / 2, my = Math.min(y0, y1) - 46;
      arc.querySelector("path").setAttribute("d", `M ${x0} ${y0} Q ${mx} ${my} ${x1} ${y1}`);
      arc.classList.add("is-drawn");
      arcLabel.style.left = `${mx}px`;
      arcLabel.style.top = `${Math.max(y0, y1) + 18}px`;
    }

    if (!calm) {
      const wait = (ms) => new Promise((r) => setTimeout(r, ms));
      let visible = true;
      new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(stage);
      const ready = async () => { while (!visible || document.hidden) await wait(400); };
      let n = 1284;

      async function upload([r, c, name, size]) {
        const box = stage.getBoundingClientRect();
        const s = local(screen.getBoundingClientRect(), box);
        const size0 = (CELL / W) * s.w;
        const x0 = s.x + (COLS[c] / W) * s.w, y0 = s.y + (ROWS[r] / H) * s.h;

        // 1. The cell is picked.
        const lift = document.createElement("span");
        lift.className = "lift";
        Object.assign(lift.style, { width: `${size0}px`, height: `${(CELL / H) * s.h}px`, transform: `translate(${x0}px, ${y0}px)` });
        stage.append(lift);
        await lift.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, fill: "forwards" }).finished;

        // 2. A new row appears at the top of the channel; the oldest one leaves.
        const li = list.firstElementChild.cloneNode(true);
        li.className = "is-uploading";
        crop(li.querySelector(".thumb"), c, r);
        li.querySelector(".name").textContent = name;
        li.querySelector(".size").textContent = size;
        li.querySelector(".progress i").style.width = "0";
        list.prepend(li);
        const rowH = li.offsetHeight;
        li.animate([{ height: "0px", opacity: 0, paddingTop: 0, paddingBottom: 0 }, { height: `${rowH}px`, opacity: 1 }], { duration: 380, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
        const old = list.lastElementChild;
        old.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300, fill: "forwards" }).finished.then(() => old.remove());

        // 3. The photo flies along an arc into the new row.
        const t = local(li.querySelector(".thumb").getBoundingClientRect(), box);
        const flyer = document.createElement("span");
        flyer.className = "flyer";
        crop(flyer, c, r);
        Object.assign(flyer.style, { width: `${size0}px`, height: `${size0}px` });
        stage.append(flyer);
        const x1 = t.x + t.w / 2, y1 = t.y + t.h / 2, cx = x0 + size0 / 2, cy = y0 + size0 / 2;
        const qx = (cx + x1) / 2, qy = Math.min(cy, y1) - 70, k = t.w / size0;
        const frames = Array.from({ length: 11 }, (_, i) => {
          const u = i / 10, a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, d = u * u;
          const x = a * cx + b * qx + d * x1, y = a * cy + b * qy + d * y1, sc = 1 + (k - 1) * u;
          return { transform: `translate(${x - size0 / 2}px, ${y - size0 / 2}px) scale(${sc})`, offset: u };
        });
        lift.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 500, delay: 250, fill: "forwards" }).finished.then(() => lift.remove());
        await flyer.animate(frames, { duration: 950, easing: "cubic-bezier(0.45, 0, 0.2, 1)", fill: "forwards" }).finished;
        li.classList.add("is-sent");
        flyer.remove();

        // 4. Upload progress, then confirmed.
        await li.querySelector(".progress i").animate([{ width: "0%" }, { width: "100%" }], { duration: 1100, easing: "cubic-bezier(0.3, 0, 0.3, 1)", fill: "forwards" }).finished;
        li.className = "";
        n += 1;
        count.textContent = n.toLocaleString("en-US");
      }

      (async () => {
        await wait(900);
        for (let i = 0; ; i = (i + 1) % queue.length) {
          await ready();
          const [r, c] = queue[i];
          // On narrow screens the card covers the lower right of the phone: only lift cells that are in view.
          if (window.innerWidth <= 960 && r > 1 && c > 1) continue;
          await upload(queue[i]);
          await wait(1000);
        }
      })();
    }

    if (document.readyState === "complete") drawPath(); else window.addEventListener("load", drawPath, { once: true });
    window.addEventListener("resize", drawPath);
  }

  // Reveal sections as they arrive.
  const reveal = document.querySelectorAll(
    "main h2, .river-caption, .details dl > div, .steps li, .privacy p, .faq-intro, .open p, .open .actions"
  );
  if (!calm && "IntersectionObserver" in window) {
    const seen = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        e.target.classList.add("is-visible");
        seen.unobserve(e.target);
      });
    }, { rootMargin: "0px 0px -8% 0px" });
    reveal.forEach((el, i) => {
      el.setAttribute("data-reveal", "");
      el.style.transitionDelay = `${(i % 4) * 60}ms`;
      seen.observe(el);
    });
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
    waitlist.hidden = false;
    const note = waitlist.querySelector(".waitlist-note");
    const button = waitlist.querySelector("button");
    waitlist.addEventListener("submit", async (event) => {
      event.preventDefault();
      button.disabled = true;
      try {
        await fetch(waitlist.action, { method: "POST", mode: "no-cors", body: new URLSearchParams(new FormData(waitlist)) });
        waitlist.classList.add("is-done");
        note.textContent = "You're on the list. We'll email you once, when Memvo is on TestFlight.";
      } catch {
        note.textContent = "That didn't go through. Check your connection and try again.";
        button.disabled = false;
      }
    });
  }
})();
