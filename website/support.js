(function () {
  var LINKS = {
    onetime: {
      url: "https://buy.polar.sh/polar_cl_5FWz1GrTSC4KMeburak4RBoRkkQQqHjuAgGzU34hNSG",
      min: 5,
      presets: [5, 10, 25, 50],
      defaultAmount: 10,
      suffix: "",
      note: "A one-time contribution that doesn\u2019t renew."
    },
    monthly: {
      url: "https://buy.polar.sh/polar_cl_lWU62kPbnZNsiyq9Vu2LVRIYAlqlIc99IXiz71qaDBC",
      min: 3,
      presets: [3, 5, 10, 25],
      defaultAmount: 5,
      suffix: "/month",
      note: "Billed monthly. Cancel any time."
    }
  };

  var freq = "onetime";
  var selectedAmount = 10;

  var tabs = document.querySelectorAll(".support-tab");
  var panelCard = document.getElementById("panel-card");
  var panelUpi = document.getElementById("panel-upi");
  var freqBtns = document.querySelectorAll(".freq-btn");
  var priceBtns = document.querySelectorAll(".price-btn");
  var customInput = document.getElementById("custom-price");
  var cta = document.getElementById("polar-cta");
  var ctaLabel = document.getElementById("polar-cta-label");
  var noteEl = document.getElementById("card-note");
  var copyBtn = document.getElementById("copy-upi");

  function setTab(target) {
    tabs.forEach(function (t) {
      var active = t.dataset.tab === target;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", active ? "true" : "false");
    });
    panelCard.hidden = target !== "card";
    panelUpi.hidden = target !== "upi";
  }

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () { setTab(tab.dataset.tab); });
  });

  if (new URLSearchParams(window.location.search).get("method") === "upi") {
    setTab("upi");
  }

  function syncCard() {
    var cfg = LINKS[freq];
    var valid = Number.isFinite(selectedAmount) && selectedAmount >= cfg.min;
    if (valid) {
      var cents = Math.round(selectedAmount * 100);
      var formatted = Number.isInteger(selectedAmount) ? String(selectedAmount) : selectedAmount.toFixed(2);
      cta.href = cfg.url + "?amount=" + cents;
      cta.classList.remove("is-disabled");
      cta.removeAttribute("aria-disabled");
      ctaLabel.textContent = "Support with $" + formatted + cfg.suffix;
    } else {
      cta.removeAttribute("href");
      cta.classList.add("is-disabled");
      cta.setAttribute("aria-disabled", "true");
      ctaLabel.textContent = "Minimum $" + cfg.min + cfg.suffix;
    }
    noteEl.textContent = cfg.note;
  }

  function applyPresets() {
    var cfg = LINKS[freq];
    priceBtns.forEach(function (btn, i) {
      var amt = cfg.presets[i];
      btn.dataset.amount = String(amt);
      btn.textContent = "$" + amt;
      var active = customInput.value === "" && selectedAmount === amt;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-pressed", active ? "true" : "false");
    });
    customInput.min = String(cfg.min);
  }

  freqBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      freq = btn.dataset.freq;
      freqBtns.forEach(function (b) {
        var active = b.dataset.freq === freq;
        b.classList.toggle("is-active", active);
        b.setAttribute("aria-pressed", active ? "true" : "false");
      });
      customInput.value = "";
      selectedAmount = LINKS[freq].defaultAmount;
      applyPresets();
      syncCard();
    });
  });

  priceBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      customInput.value = "";
      selectedAmount = Number(btn.dataset.amount);
      applyPresets();
      syncCard();
    });
  });

  customInput.addEventListener("input", function () {
    var raw = customInput.value.trim();
    if (raw === "") {
      selectedAmount = LINKS[freq].defaultAmount;
    } else {
      selectedAmount = Number(raw);
    }
    priceBtns.forEach(function (btn) {
      btn.classList.remove("is-active");
      btn.setAttribute("aria-pressed", "false");
    });
    syncCard();
  });

  if (copyBtn) {
    copyBtn.addEventListener("click", function () {
      var id = document.getElementById("upi-id").textContent.trim();
      if (navigator.clipboard) {
        navigator.clipboard.writeText(id).then(function () {
          copyBtn.textContent = "Copied";
          setTimeout(function () { copyBtn.textContent = "Copy UPI ID"; }, 1800);
        });
      }
    });
  }

  applyPresets();
  syncCard();
})();
