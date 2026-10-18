//
//  VGScript.mm
//  注入到页面的抓取脚本（C++ 原始字符串，避免转义地狱）
//

#import "VGScript.h"

static const char *kVGScript = R"XLHJS(
(function () {
  if (window.__XLH_VG__) return;
  window.__XLH_VG__ = true;

  var MAX_ITEMS = 400;
  var EXT = {
    m3u8: 'hls', m3u: 'hls', mpd: 'dash',
    mp4: 'progressive', m4v: 'progressive', mov: 'progressive',
    webm: 'progressive', mkv: 'progressive', flv: 'progressive', '3gp': 'progressive',
    ts: 'segment',
    mp3: 'audio', m4a: 'audio', aac: 'audio', ogg: 'audio', oga: 'audio', wav: 'audio', opus: 'audio'
  };
  var ORDER = { hls: 0, dash: 1, progressive: 2, audio: 3, segment: 4, unknown: 5 };

  var map = {};
  var list = [];

  function abs(u) {
    try { return new URL(u, document.baseURI).href; } catch (e) { return null; }
  }

  function kindOf(u) {
    var s = String(u).split('#')[0];
    var m = s.match(/\.([a-z0-9]{2,5})(?:$|[?&;])/i);
    if (m && EXT[m[1].toLowerCase()]) return EXT[m[1].toLowerCase()];
    if (/m3u8/i.test(s)) return 'hls';
    if (/\.mpd(?:$|[?&])/i.test(s)) return 'dash';
    return '';
  }

  function report(item) {
    try {
      window.webkit.messageHandlers.xlhgrab.postMessage({
        url: item.url,
        kind: item.kind,
        source: item.source,
        page: location.href
      });
    } catch (e) {}
  }

  function add(raw, source, force) {
    try {
      if (!raw || typeof raw !== 'string') return;
      var u = raw.trim();
      if (u.length < 10 || u.length > 4096) return;
      if (/^(blob|data|javascript|about|mailto|file):/i.test(u)) return;
      u = abs(u);
      if (!u || !/^https?:/i.test(u)) return;
      var k = kindOf(u);
      if (!k && !force) return;
      if (!k) k = 'unknown';
      if (map[u]) { map[u].hits++; return; }
      if (list.length >= MAX_ITEMS) return;
      var item = { url: u, kind: k, source: source || '', hits: 1, t: Date.now() };
      map[u] = item;
      list.push(item);
      report(item);
    } catch (e) {}
  }

  /* ---------- 网络层拦截 ---------- */

  try {
    var xhrOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (m, url) {
      try { add(url, 'xhr'); } catch (e) {}
      return xhrOpen.apply(this, arguments);
    };
  } catch (e) {}

  try {
    if (window.fetch) {
      var origFetch = window.fetch;
      window.fetch = function (input) {
        try {
          var u = (typeof input === 'string') ? input : (input && input.url);
          add(u, 'fetch');
        } catch (e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch (e) {}

  /* ---------- 媒体元素 ---------- */

  function hookSetter(proto, prop, source) {
    try {
      var d = Object.getOwnPropertyDescriptor(proto, prop);
      if (!d || !d.set) return;
      Object.defineProperty(proto, prop, {
        configurable: true,
        enumerable: d.enumerable,
        get: d.get,
        set: function (v) {
          try { add(v, source, true); } catch (e) {}
          return d.set.call(this, v);
        }
      });
    } catch (e) {}
  }

  if (window.HTMLMediaElement) hookSetter(HTMLMediaElement.prototype, 'src', 'media.src');
  if (window.HTMLSourceElement) hookSetter(HTMLSourceElement.prototype, 'src', 'source.src');

  try {
    document.addEventListener('loadstart', function (ev) {
      var t = ev.target;
      if (!t) return;
      if (t.currentSrc) add(t.currentSrc, 'loadstart', true);
      else if (t.src) add(t.src, 'loadstart', true);
    }, true);
  } catch (e) {}

  /* ---------- 资源计时 ---------- */

  try {
    var po = new PerformanceObserver(function (entries) {
      entries.getEntries().forEach(function (e) { add(e.name, 'perf'); });
    });
    po.observe({ entryTypes: ['resource'] });
  } catch (e) {}

  try {
    performance.getEntriesByType('resource').forEach(function (e) { add(e.name, 'perf'); });
  } catch (e) {}

  /* ---------- DOM / HTML 扫描 ---------- */

  function scanDom() {
    try {
      var nodes = document.querySelectorAll('video, audio, source, track, [data-src], [data-video], [data-hls], [data-mp4], [data-url]');
      var attrs = ['src', 'data-src', 'data-video', 'data-hls', 'data-mp4', 'data-url', 'data-file'];
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        try { if (n.currentSrc) add(n.currentSrc, 'dom', true); } catch (e) {}
        try { if (n.src) add(n.src, 'dom', true); } catch (e) {}
        for (var j = 0; j < attrs.length; j++) {
          var v = n.getAttribute && n.getAttribute(attrs[j]);
          if (v) add(v, 'dom', true);
        }
      }
    } catch (e) {}

    try {
      var metas = document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"], meta[name="twitter:player:stream"], meta[itemprop="contentUrl"]');
      for (var k = 0; k < metas.length; k++) {
        var c = metas[k].getAttribute('content');
        if (c) add(c, 'meta', true);
      }
    } catch (e) {}
  }

  function scanHTML() {
    var html = '';
    try { html = document.documentElement ? document.documentElement.innerHTML : ''; } catch (e) {}
    if (!html) return;
    if (html.length > 1500000) html = html.slice(0, 1500000);
    var guard = 0, m;
    var re1 = /(?:https?:)?\/\/[^\s"'<>()\\]+?\.(?:m3u8|mpd|mp4|m4v|webm|mov)(?:\?[^\s"'<>()\\]*)?/gi;
    while ((m = re1.exec(html)) && guard++ < 120) add(m[0], 'html');
    guard = 0;
    var re2 = /["'](\/[^"'\s<>\\]+?\.(?:m3u8|mp4|mpd)(?:\?[^"'\s<>\\]*)?)["']/gi;
    while ((m = re2.exec(html)) && guard++ < 120) add(m[1], 'html');
  }

  try { setInterval(scanDom, 2500); } catch (e) {}
  try { document.addEventListener('DOMContentLoaded', scanDom); } catch (e) {}
  try { setTimeout(scanDom, 500); } catch (e) {}

  /* ---------- 对外接口 ---------- */

  window.__xlhCollect = function () {
    scanDom();
    try { scanHTML(); } catch (e) {}
    var out = list.slice().sort(function (a, b) {
      var d = (ORDER[a.kind] || 9) - (ORDER[b.kind] || 9);
      if (d !== 0) return d;
      return b.t - a.t;
    });
    return JSON.stringify({ page: location.href, items: out });
  };

  window.__xlhCount = function () { return list.length; };
})();
)XLHJS";

NSString *VGScriptSource(void) {
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = [NSString stringWithUTF8String:kVGScript] ?: @"";
    });
    return source;
}
