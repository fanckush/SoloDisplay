// Umami events. Umami records page views, referrers and UTM tags by itself; this adds
// the actions that matter (downloads, installs, GitHub and sponsor clicks) and the
// signals around them (demo use, FAQ questions, scroll depth). Every event carries the
// visitor's source, resolved once per session, so conversions can be split by channel.
// If Umami is blocked or not loaded, nothing is sent and nothing breaks.
(function () {
  var STORAGE_KEY = "sd-source";

  // utm_source values we or others use, mapped to one name per channel.
  var UTM_ALIASES = {
    hn: "hackernews", hackernews: "hackernews",
    twitter: "x", x: "x",
    reddit: "reddit",
    producthunt: "producthunt", ph: "producthunt",
    github: "github", readme: "github",
    newsletter: "email", email: "email", mail: "email"
  };

  // Referrer hosts, mapped the same way. Anything else is reported by host name.
  var REFERRERS = [
    [/(^|\.)google\./, "google"],
    [/(^|\.)bing\.com$/, "bing"],
    [/(^|\.)duckduckgo\.com$/, "duckduckgo"],
    [/(^|\.)(kagi|ecosia|search\.brave)\./, "search_other"],
    [/(^|\.)reddit\.com$/, "reddit"],
    [/^news\.ycombinator\.com$/, "hackernews"],
    [/^(t\.co|x\.com|twitter\.com)$/, "x"],
    [/(^|\.)producthunt\.com$/, "producthunt"],
    [/(^|\.)github\.com$/, "github"],
    [/(^|\.)(youtube\.com|youtu\.be)$/, "youtube"],
    [/(^|\.)(chatgpt\.com|openai\.com|perplexity\.ai|claude\.ai)$/, "ai_assistant"]
  ];

  function resolveSource() {
    try {
      var cached = sessionStorage.getItem(STORAGE_KEY);
      if (cached) return JSON.parse(cached);
    } catch (e) {}

    var params = new URLSearchParams(location.search);
    var utm = (params.get("utm_source") || "").toLowerCase();
    var source = "direct";
    if (utm) {
      source = UTM_ALIASES[utm] || utm;
    } else if (document.referrer) {
      try {
        var host = new URL(document.referrer).hostname;
        source = host === location.hostname ? "internal" : host.replace(/^www\./, "");
        for (var i = 0; i < REFERRERS.length; i++) {
          if (REFERRERS[i][0].test(host)) { source = REFERRERS[i][1]; break; }
        }
      } catch (e) { source = "external"; }
    }

    var resolved = { source: source, landing: location.pathname };
    if (params.get("utm_medium")) resolved.medium = params.get("utm_medium");
    if (params.get("utm_campaign")) resolved.campaign = params.get("utm_campaign");
    try { sessionStorage.setItem(STORAGE_KEY, JSON.stringify(resolved)); } catch (e) {}
    return resolved;
  }

  var source = resolveSource();

  function track(name, data) {
    try {
      if (!window.umami) return;
      var payload = {};
      for (var k in source) payload[k] = source[k];
      for (var j in data) payload[j] = data[j];
      window.umami.track(name, payload);
    } catch (e) {}
  }

  // Where on the page something was clicked, from its surroundings.
  function placement(el) {
    if (el.closest(".top")) return "nav";
    if (el.closest(".hero")) return "hero";
    if (el.closest("#faq")) return "faq";
    if (el.closest("#features")) return "features";
    if (el.closest(".crumbs")) return "breadcrumb";
    if (el.closest(".prose")) return "guide";
    if (el.closest("footer")) return "footer";
    return "page";
  }

  var REPO = "github.com/fanckush/SoloDisplay";

  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest("a, #copy");
    if (!el) return;
    var where = placement(el);

    if (el.id === "copy") return track("brew_copy", { placement: where });

    var url;
    try { url = new URL(el.href, location.href); } catch (err) { return; }
    var path = url.hostname + url.pathname.replace(/\/$/, "");

    if (/\.dmg$/.test(url.pathname)) return track("download", { placement: where });
    if (url.hostname === "github.com" && url.pathname.indexOf("/sponsors/") === 0) {
      return track("sponsor_click", { placement: where });
    }
    if (path === REPO) return track("github_click", { placement: where });
    if (path.indexOf(REPO + "/") === 0) {
      // releases, issues, blob/main/LICENSE, ...
      return track("repo_link_click", { placement: where, target: path.slice(REPO.length + 1).split("/")[0] });
    }
    if (url.hostname !== location.hostname) {
      return track("outbound_click", { placement: where, url: path });
    }
    if (/\/guide\//.test(url.pathname) && url.pathname !== location.pathname) {
      return track("guide_click", { placement: where });
    }
  });

  // Interactive demos: once per demo per page view, with the first control used.
  var engaged = {};
  function demoUsed(el, control) {
    var demo = el.closest(".demo");
    if (!demo || engaged[demo.id]) return;
    engaged[demo.id] = true;
    track("demo_engaged", { demo: demo.id.replace(/-demo$/, ""), control: control });
  }
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest(".seg button");
    if (b) demoUsed(b, "mode:" + b.dataset.mode);
  });
  document.addEventListener("change", function (e) {
    if (e.target.closest && e.target.closest(".plug")) demoUsed(e.target, e.target.checked ? "plug_in" : "unplug");
  });

  // FAQ: which questions get opened. The toggle event doesn't bubble, so listen while it travels down.
  document.addEventListener("toggle", function (e) {
    var d = e.target;
    if (d.tagName === "DETAILS" && d.open && d.id) track("faq_open", { question: d.id });
  }, true);

  // Scroll depth, once per threshold per page view.
  var marks = [25, 50, 75, 100], sent = {}, ticking = false;
  function depth() {
    ticking = false;
    var doc = document.documentElement;
    var scrollable = doc.scrollHeight - window.innerHeight;
    var pct = scrollable <= 0 ? 100 : Math.round((window.scrollY / scrollable) * 100);
    marks.forEach(function (m) {
      if (pct >= m && !sent[m]) { sent[m] = true; track("scroll_depth", { percent: m }); }
    });
  }
  window.addEventListener("scroll", function () {
    if (!ticking) { ticking = true; requestAnimationFrame(depth); }
  }, { passive: true });
})();
