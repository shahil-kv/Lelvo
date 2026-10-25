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

  // Hero: photos leave the phone and land in the channel list. Positions are measured, so it fits any layout.
  const stage = document.querySelector(".hero-stage");
  function fly() {
    if (calm || !stage || window.innerWidth <= 960) return;
    const phone = stage.querySelector(".hero-phone").getBoundingClientRect();
    const box = stage.getBoundingClientRect();
    const targets = stage.querySelectorAll(".files img");
    stage.querySelectorAll(".flight img").forEach((img, i) => {
      const t = targets[i].getBoundingClientRect();
      const w0 = phone.width * 0.3, h0 = w0;
      const x0 = phone.left - box.left + phone.width * (0.08 + (i % 3) * 0.31);
      const y0 = phone.top - box.top + phone.height * (0.2 + Math.floor(i / 3) * 0.14);
      img.style.setProperty("--x0", `${x0}px`);
      img.style.setProperty("--y0", `${y0}px`);
      img.style.setProperty("--w0", `${w0}px`);
      img.style.setProperty("--h0", `${h0}px`);
      img.style.setProperty("--dx", `${t.left - box.left - x0}px`);
      img.style.setProperty("--dy", `${t.top - box.top - y0}px`);
      img.style.setProperty("--s", `${t.width / w0}`);
      img.style.transformOrigin = "0 0";
    });
    stage.classList.add("is-flying");
    // Each row shows its photo and tick as its flight lands (timers, so the end state never depends on an animation).
    stage.querySelectorAll(".files li").forEach((li, i) => setTimeout(() => li.classList.add("is-landed"), 1600 + i * 450));
  }
  if (document.readyState === "complete") fly(); else window.addEventListener("load", fly, { once: true });

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
})();
