/* Shared logic for the Parkour mock portals (mockpark, guestpass).
 * Fictional vendors for demos only. Contract: API_CONTRACT.md section 8.
 *
 * URL params: property=<property_code>, any canonical field as prefill,
 *             captcha=on (fake challenge), fail=1 (forced error on submit).
 */
(function () {
  "use strict";

  var CANONICAL = ["plate", "state", "make", "model", "color", "host_unit", "host_name",
                   "guest_name", "phone", "email", "duration_hours"];
  /* Same list as agent/services/runner.py REQUIRED; host_unit added per property rules. */
  var ALWAYS_REQUIRED = ["plate", "state", "make", "model", "color", "guest_name",
                         "phone", "duration_hours"];
  var NIGHT_PREFIX = "pk_nights:";

  var params = new URLSearchParams(window.location.search);

  function store(fn, fallback) {
    try { return fn(window.localStorage); } catch (e) { return fallback; }
  }

  function monthKey(d) {
    return d.getUTCFullYear() + "-" + String(d.getUTCMonth() + 1).padStart(2, "0");
  }

  function normPlate(p) {
    return String(p || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  }

  function nightKey(code, plate) {
    return NIGHT_PREFIX + code + ":" + normPlate(plate) + ":" + monthKey(new Date());
  }

  function nightsUsed(code, plate) {
    return store(function (s) { return parseInt(s.getItem(nightKey(code, plate)) || "0", 10); }, 0);
  }

  function addNight(code, plate) {
    store(function (s) { s.setItem(nightKey(code, plate), String(nightsUsed(code, plate) + 1)); }, null);
  }

  function resetNights() {
    store(function (s) {
      var keys = [];
      for (var i = 0; i < s.length; i++) {
        var k = s.key(i);
        if (k && k.indexOf(NIGHT_PREFIX) === 0) keys.push(k);
      }
      keys.forEach(function (k) { s.removeItem(k); });
    }, null);
  }

  function confirmationNumber() {
    var chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var out = "PK-";
    var buf = new Uint32Array(6);
    window.crypto.getRandomValues(buf);
    for (var i = 0; i < 6; i++) out += chars[buf[i] % chars.length];
    return out;
  }

  function isoNoMillis(d) {
    return d.toISOString().replace(/\.\d{3}Z$/, "Z");
  }

  function loadRules() {
    return fetch("../rules.json", { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("rules.json " + r.status); return r.json(); })
      .then(function (j) { return j.properties || {}; });
  }

  /* ---- error box ---- */
  function showError(box, message, field) {
    box.textContent = message;
    if (field) box.setAttribute("data-field", field); else box.removeAttribute("data-field");
    box.hidden = false;
    box.scrollIntoView({ block: "center", behavior: "auto" });
  }
  function clearError(box) {
    box.hidden = true;
    box.textContent = "";
    box.removeAttribute("data-field");
  }

  /* ---- fake CAPTCHA (clearly fake; for the human hand-off demo) ---- */
  function mountCaptcha(container) {
    var answer = "";
    container.setAttribute("data-testid", "captcha");
    container.innerHTML =
      '<p class="captcha-title">Demo verification</p>' +
      '<p class="captcha-help">Type the letters you see. This is a fake challenge for the Parkour demo.</p>' +
      '<div class="captcha-glyphs" aria-hidden="true"></div>' +
      '<div class="captcha-row">' +
      '<label for="captcha-answer" class="sr-only">Letters shown</label>' +
      '<input id="captcha-answer" name="captcha_answer" autocomplete="off" autocapitalize="characters" inputmode="text" placeholder="Letters">' +
      '<button type="button" class="captcha-new">New letters</button>' +
      "</div>";
    var glyphs = container.querySelector(".captcha-glyphs");
    function regen() {
      var chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
      answer = "";
      glyphs.innerHTML = "";
      for (var i = 0; i < 5; i++) {
        var c = chars[Math.floor(Math.random() * chars.length)];
        answer += c;
        var s = document.createElement("span");
        s.textContent = c;
        s.style.transform = "rotate(" + (Math.random() * 40 - 20).toFixed(0) + "deg) translateY(" + (Math.random() * 8 - 4).toFixed(0) + "px)";
        glyphs.appendChild(s);
      }
      glyphs.setAttribute("data-len", "5");
      container.querySelector("#captcha-answer").value = "";
    }
    container.querySelector(".captcha-new").addEventListener("click", regen);
    regen();
    container.hidden = false;
    return {
      solved: function () {
        return container.querySelector("#captcha-answer").value.trim().toUpperCase() === answer;
      }
    };
  }

  /* ---- the registration decision, shared by both vendors ---- */
  function process(values, rule, captcha) {
    if (params.get("fail") === "1") {
      return { error: "Service temporarily unavailable (error 503). Please try again later.", field: null, page: true };
    }
    if (captcha && !captcha.solved()) {
      return { error: "Complete the verification challenge before submitting.", field: null };
    }
    var required = ALWAYS_REQUIRED.slice();
    if (rule.requires_host_unit) required.push("host_unit");
    for (var i = 0; i < required.length; i++) {
      var f = required[i];
      if (!String(values[f] || "").trim()) {
        return { error: "Missing required field: " + f, field: f };
      }
    }
    var hours = Number(values.duration_hours);
    if (!isFinite(hours) || hours <= 0) {
      return { error: "Invalid value for duration_hours.", field: "duration_hours" };
    }
    if (rule.max_duration_hours && hours > rule.max_duration_hours) {
      return { error: "Duration exceeds the " + rule.max_duration_hours + " hour maximum for this property.", field: "duration_hours" };
    }
    var used = nightsUsed(values._code, values.plate);
    if (rule.max_nights_per_month && used >= rule.max_nights_per_month) {
      return {
        error: "This vehicle has reached the guest night limit for this property (" +
               rule.max_nights_per_month + " per month).",
        field: null
      };
    }
    addNight(values._code, values.plate);
    var expires = new Date(Date.now() + hours * 3600 * 1000);
    return {
      ok: true,
      confirmation_number: confirmationNumber(),
      expires_at: isoNoMillis(expires),
      expires_local: expires.toLocaleString([], { dateStyle: "medium", timeStyle: "short" }),
      plate: normPlate(values.plate),
      state: String(values.state).toUpperCase(),
      property_name: rule.name,
      nights_used: used + 1,
      nights_max: rule.max_nights_per_month || null
    };
  }

  function renderSuccess(target, r) {
    target.innerHTML =
      '<div class="success" data-testid="success">' +
      '<p class="success-kicker">Guest pass issued</p>' +
      '<p class="conf-label">Confirmation number</p>' +
      '<p class="conf" data-testid="confirmation-number"></p>' +
      '<dl class="facts">' +
      '<div><dt>Property</dt><dd data-testid="property-name"></dd></div>' +
      '<div><dt>Vehicle</dt><dd data-testid="plate"></dd></div>' +
      '<div><dt>Valid until</dt><dd><span class="expires-local"></span><br><code data-testid="expires-at"></code></dd></div>' +
      '<div><dt>Guest nights this month</dt><dd class="nights"></dd></div>' +
      "</dl>" +
      '<p class="success-note">Keep this page as proof of registration.</p>' +
      "</div>";
    target.querySelector('[data-testid="confirmation-number"]').textContent = r.confirmation_number;
    target.querySelector('[data-testid="property-name"]').textContent = r.property_name;
    target.querySelector('[data-testid="plate"]').textContent = r.plate + " (" + r.state + ")";
    target.querySelector('[data-testid="expires-at"]').textContent = r.expires_at;
    target.querySelector(".expires-local").textContent = r.expires_local;
    target.querySelector(".nights").textContent = r.nights_max ? (r.nights_used + " of " + r.nights_max) : String(r.nights_used);
    document.title = "Pass " + r.confirmation_number;
  }

  function renderFailPage(target, message) {
    target.innerHTML =
      '<div class="failpage"><p class="fail-code">503</p>' +
      '<p data-testid="error" class="error"></p>' +
      '<p class="fail-help">No registration was created.</p></div>';
    target.querySelector('[data-testid="error"]').textContent = message;
  }

  function wireFooter() {
    var btn = document.getElementById("reset-nights");
    if (btn) btn.addEventListener("click", function () {
      resetNights();
      btn.textContent = "Demo counters cleared";
    });
  }

  window.PK = {
    CANONICAL: CANONICAL,
    params: params,
    loadRules: loadRules,
    mountCaptcha: mountCaptcha,
    process: process,
    renderSuccess: renderSuccess,
    renderFailPage: renderFailPage,
    showError: showError,
    clearError: clearError,
    wireFooter: wireFooter
  };
})();
