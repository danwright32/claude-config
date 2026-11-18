/* capture-chrome.js: save the product's real page as a design round's chrome (claude-config#1364).

   Run in the MAIN session's browser, on the product's page, signed in as the person the screen is
   for, with the window at the width the round is drawn at. It makes the page one self contained
   document: the markup as it renders now, every stylesheet the page uses inlined, every font and
   image those stylesheets name inlined as data, and every script taken out (the chrome is drawn,
   never run).

   THE PAGE'S POLICY, AS csp (claude-config#2894). Every font, image and the page's own markup is read
   with fetch(), which the page's content security policy governs, and a read the policy refuses is
   reported to whoever it names, which can page Dan as the loopback post of #2774 did. Page script
   cannot see a policy the server sent as a response header (measured 2026-11-17), so pass it: the text
   of the page's Content-Security-Policy and Content-Security-Policy-Report-Only headers, joined by
   ", ", or "" when its server sends neither. A policy in the page's meta tag is read here. A read every
   policy allows is made; any other is named in the first comment and never attempted. Given no csp,
   nothing is read over the network at all, and the first comment says so. Should the page refuse a read
   anyway (the csp given was not its whole policy), every read after it is skipped and the refusal named.

   Two routes, by which browser tools the session has:

   Playwright: browser_evaluate, with this file's text wrapped as the function

     () => (<this file's text>)({csp: "<the page's policy headers>"})

   It answers with the document.

   Claude in Chrome (claude-config#2774): the javascript tool, in the tab the session opened, with this
   file's text wrapped as

     await (<this file's text>)({saveAs: "chrome-<round>-<yyyymmddhhmm>.html", csp: "<the page's policy headers>"})

   The page then saves the document itself, as a download into the Downloads folder, and answers with
   one line: the file name, its size in bytes, and the first comment below. Check the file is in
   ~/Downloads at exactly that size before moving it beside the round; if it is not there, stop and
   say so (Chrome may be set to ask where to save, or to ask before a site's second download, and
   either is Dan's to answer). A file name that is not a plain name ending in .html is refused.

   NEVER POST THE PAGE ANYWHERE. Never start a receiver (on this Mac's loopback address or any other)
   and have the page send its copy to it. A production page's content security policy
   refuses the request and reports the refusal, which paged Dan with nothing to act on twice
   (2026-11-01 and 2026-11-11, claude-config#2774). The download above sends nothing over the network.
   chrome-loopback-post-gate.sh refuses a Claude in Chrome script naming a loopback address beside a
   network call, so this file must never name one itself; that gate's suite runs it as its control.

   Save the document as the round's chrome.html, and name it in the spec:

     "chrome": {"captured": "chrome.html", "from": "<the URL, who was signed in, the date>",
                "slot": "#<the id of the element the round draws into>", "width": <the window width>}

   A stylesheet the page cannot read (another origin's, without CORS) and a font or image that cannot
   be fetched, or that the page's policy does not allow reading, are listed in the answer's first
   comment, never silently left out: a chrome missing its font draws in a fallback font, and every
   picture compared against it differs.

   A theme on <html> (data-theme, a "dark" or "light" class, an inline color-scheme) that the page's
   own script set is taken out, so the chrome follows the same theme rule as the built page rather
   than whichever theme the capture ran in (claude-config#2045); one in the markup the server sent is
   kept. The first comment names either, and says so when the served markup could not be read. */
async (options) => {
  // {csp: "<the page's policy headers>"} on both routes, and {saveAs: "<a file name>.html"} on the Chrome route.
  const opts = options && typeof options === "object" ? options : {};
  const saveAs = typeof opts.saveAs === "string" ? opts.saveAs : "";
  if ("saveAs" in opts && !/^[A-Za-z0-9][A-Za-z0-9._ -]*\.html$/.test(saveAs)) {
    throw new Error("saveAs must be a plain file name ending in .html, with no folder: " + JSON.stringify(opts.saveAs));
  }
  if ("csp" in opts && typeof opts.csp !== "string") {
    throw new Error("csp must be the text of the page's Content-Security-Policy and Content-Security-Policy-Report-Only " +
      'response headers, or "" when its server sends neither: ' + JSON.stringify(opts.csp));
  }
  // What the page's content security policy lets this page connect to (claude-config#2894). Every read
  // below is a fetch, which the policy's connect-src (or default-src) governs, and a read it refuses is
  // reported to whoever the policy names, which can page Dan. Page script cannot see a policy the server
  // sent by header, so the caller passes it as csp; one in a meta tag is read here. A report only policy
  // reports what it would refuse just the same, so it counts as refusing. Each policy must allow a read.
  const given = typeof opts.csp === "string";
  const policies = [];
  const addPolicy = (text, from) => {
    const directives = {};
    for (const part of text.split(";")) {
      const tokens = part.trim().split(/\s+/).filter(Boolean);
      if (tokens.length && !(tokens[0].toLowerCase() in directives)) directives[tokens[0].toLowerCase()] = tokens.slice(1);
    }
    const list = directives["connect-src"] || directives["default-src"];
    if (list) policies.push({ from, list });
  };
  if (given) for (const one of opts.csp.split(",")) addPolicy(one, "the header given as csp");
  for (const meta of document.querySelectorAll("meta[http-equiv]")) {
    if (meta.getAttribute("http-equiv").trim().toLowerCase() === "content-security-policy") {
      addPolicy(meta.getAttribute("content") || "", "its meta tag");
    }
  }
  const page = new URL(location.href);
  const upgrades = (want, got) => want === got || (want === "http:" && got === "https:") || (want === "ws:" && got === "wss:");
  // One source expression against one URL, as CSP matches them. Anything it does not recognise (a
  // nonce, a hash, a keyword) allows nothing, so a policy it misreads refuses rather than permits.
  const allows = (source, url) => {
    const s = source.toLowerCase();
    if (s === "*") return /^(https?|wss?):$/.test(url.protocol) || url.protocol === page.protocol;
    if (s === "'self'") return url.origin === page.origin || (url.host === page.host && upgrades(page.protocol, url.protocol));
    if (/^[a-z][a-z0-9+.-]*:$/.test(s)) return upgrades(s, url.protocol);
    const m = /^(?:([a-z][a-z0-9+.-]*):\/\/)?(\*|(?:\*\.)?[a-z0-9.-]+)(?::(\d+|\*))?(\/[^?#]*)?$/i.exec(source);
    if (!m) return false;
    const scheme = m[1] ? m[1].toLowerCase() + ":" : page.protocol;
    const host = m[2].toLowerCase();
    if (!upgrades(scheme, url.protocol)) return false;
    if (host !== "*" && (host.startsWith("*.") ? !url.hostname.endsWith(host.slice(1)) : url.hostname !== host)) return false;
    if (m[3] ? m[3] !== "*" && url.port !== m[3] && !(url.port === "" && ({ "http:": "80", "https:": "443" })[url.protocol] === m[3])
      : url.port !== "") return false;
    if (m[4] && (m[4].endsWith("/") ? !url.pathname.startsWith(m[4]) : url.pathname !== m[4])) return false;
    return true;
  };
  // A refusal the page reports anyway (a policy given that is not the page's whole policy) stops every
  // read after it, so one wrong policy costs one report, never one for each font and image.
  const refusedByPage = [];
  const onRefused = (e) => refusedByPage.push(e.blockedURI || "a read");
  document.addEventListener("securitypolicyviolation", onRefused);
  const read = async (href) => {
    if (!given) throw new Error("not read, no csp given");
    if (refusedByPage.length) throw new Error("not read, after the page refused an earlier read");
    const before = refusedByPage.length;
    const url = new URL(href);
    const refusing = policies.find((p) => !p.list.some((source) => allows(source, url)));
    if (refusing) throw new Error("not read, since the page's content security policy (" + refusing.from + ") does not allow connecting to it");
    try {
      // Credentials go only to the page's own origin (fetch's default): an asset host that answers any
      // origin, as font hosts do, refuses a read that carries them. A redirect is not followed, since
      // the policy is checked again wherever it lands.
      const res = await fetch(href, { redirect: "manual" });
      if (res.type === "opaqueredirect") throw new Error("not read: it redirects, and a redirect is not followed");
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res;
    } catch (e) {
      // The page reports a refusal as an event after the read fails; wait for it before the next read.
      await new Promise((ok) => setTimeout(ok, 50));
      throw refusedByPage.length > before ? new Error("refused by the page's content security policy") : e;
    }
  };
  const missing = [];
  const toData = async (url) => {
    try {
      const res = await read(url);
      const blob = await res.blob();
      return await new Promise((ok, no) => {
        const r = new FileReader();
        r.onload = () => ok(r.result);
        r.onerror = () => no(r.error);
        r.readAsDataURL(blob);
      });
    } catch (e) {
      missing.push(url + " (" + String(e && e.message ? e.message : e) + ")");
      return null;
    }
  };
  const inlineUrls = async (css, base) => {
    const found = [...css.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g)];
    let out = css;
    for (const m of found) {
      const ref = m[2];
      if (ref.startsWith("data:") || ref.startsWith("#")) continue;
      const data = await toData(new URL(ref, base).href);
      if (data) out = out.split(m[0]).join('url("' + data + '")');
    }
    return out;
  };
  let css = "";
  for (const sheet of [...document.styleSheets]) {
    let rules;
    try {
      rules = [...sheet.cssRules];
    } catch (e) {
      missing.push((sheet.href || "an inline stylesheet") + " (its rules cannot be read from this page)");
      continue;
    }
    css += (await inlineUrls(rules.map((r) => r.cssText).join("\n"), sheet.href || location.href)) + "\n";
  }
  const root = document.documentElement.cloneNode(true);
  // The theme on <html> follows the same rule as the page it came from (claude-config#2045). A theme
  // the page's own boot script stamped there (from a stored preference, a cookie, the clock) is put
  // back as the server sent it, since the chrome is drawn with every script out and the build follows
  // whoever is signed in; a theme in the served markup itself is kept, since the build is served the
  // same way. Either way the first comment names what was taken out or what the chrome is pinned to.
  const themeMarks = (el) => {
    const marks = [];
    if (el.hasAttribute("data-theme")) marks.push('data-theme="' + el.getAttribute("data-theme") + '"');
    for (const c of ["dark", "light"]) if (el.classList.contains(c)) marks.push('class "' + c + '"');
    if (el.style && el.style.colorScheme) marks.push("color-scheme: " + el.style.colorScheme);
    return marks;
  };
  let themeNote = "";
  const liveMarks = themeMarks(document.documentElement);
  let served = null;
  let unread = "";
  try {
    const res = await read(location.href);
    served =new DOMParser().parseFromString(await res.text(), "text/html").documentElement;
  } catch (e) {
    unread = String(e && e.message ? e.message : e);
  }
  if (served) {
    if (served.hasAttribute("data-theme")) root.setAttribute("data-theme", served.getAttribute("data-theme"));
    else root.removeAttribute("data-theme");
    for (const c of ["dark", "light"]) root.classList.toggle(c, served.classList.contains(c));
    if (!root.getAttribute("class")) root.removeAttribute("class");
    root.style.colorScheme = served.style.colorScheme || "";
    if (!root.getAttribute("style")) root.removeAttribute("style");
    const servedMarks = themeMarks(served);
    const stamped = liveMarks.filter((m) => !servedMarks.includes(m));
    if (stamped.length) themeNote += "; theme the page's script set on <html> taken out: " + stamped.join(", ");
    if (servedMarks.length) themeNote += "; theme pinned by the served page's own <html>, so kept: " + servedMarks.join(", ");
  } else if (liveMarks.length) {
    themeNote = "; theme pinned on <html>, kept because the served page could not be read to tell whether its script set it (" +
      unread + "): " + liveMarks.join(", ");
  }
  root.querySelectorAll("script, noscript, link[rel~='stylesheet'], link[rel='preload'], link[rel='modulepreload'], style").forEach((n) => n.remove());
  for (const img of root.querySelectorAll("img[src]")) {
    const src = img.getAttribute("src");
    if (src.startsWith("data:")) continue;
    const data = await toData(new URL(src, location.href).href);
    if (data) { img.setAttribute("src", data); img.removeAttribute("srcset"); }
  }
  const style = document.createElement("style");
  style.textContent = css;
  root.querySelector("head").append(style);
  document.removeEventListener("securitypolicyviolation", onRefused);
  const policyNote = !given
    ? "; nothing was read over the network, the page's own markup included, because the content security policy the page's " +
      'server sent was not given (pass the text of its Content-Security-Policy headers as csp, or "" when it sends none)'
    : refusedByPage.length
      ? "; the page's content security policy REFUSED reading " + refusedByPage.join(", ") +
        ", so the csp given is not the page's whole policy, and nothing after it was read"
      : "";
  const note = "<!-- captured from " + location.href + " at " + window.innerWidth + " wide on " + new Date().toISOString() +
    (missing.length ? "; NOT inlined, so drawn without: " + missing.join("; ") : "; every stylesheet, font and image inlined") +
    policyNote + themeNote + " -->";
  const doc = "<!doctype html>\n" + note + "\n" + root.outerHTML;
  if (!saveAs) return doc;
  // The Claude in Chrome route: the page saves the capture itself, as a download, so nothing is sent
  // over the network and no receiver is needed (claude-config#2774).
  const blob = new Blob([doc], { type: "text/html" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = saveAs;
  link.style.display = "none";
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(link.href), 60000);
  return "saved " + saveAs + " to the Downloads folder, " + blob.size + " bytes. " + note;
}
