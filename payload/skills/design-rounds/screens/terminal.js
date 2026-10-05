/* The Claude Code terminal, dark, for design rounds about mods (claude-config#651).

   A spec asks for it with "screen": "terminal", and make-switcher.py puts this file and
   terminal.css on the page ahead of the round's own builder. The builder then states only
   what varies:

     function buildScreen(variant) {
       var T = Terminal;
       return T.screen({
         title: "claude-config",
         transcript: [T.user("keep going"), "Merging #653 once its checks pass."],
         band: [[T.amber("Work has more room"), "  ", T.button("Switch")]]
       });

   The status line is the built one unless the round names other segments, which are text only:
   the real line is all grey, divided by |.
     }

   Everything lives under the one name Terminal. Every hand written round declared its own
   el, span and line at the top level, and a library declaring those too would be silently
   replaced by the builder's, so nothing here reaches the page's top level but that name.

   Anything misspelt THROWS, naming what it did not recognise: a style, a card kind, an
   option. The switcher reports a throwing builder on the page, quoting the message, so a
   typo is a sentence on screen rather than a colour that quietly is not there. */
var Terminal = (function () {
  "use strict";

  var STYLES = ["amber", "grey", "red", "violet", "bold", "dim", "white"];
  var CARDS = ["box", "rule", "none"];
  var EDGES = ["grey", "amber", "violet", "red"];
  var OPTIONS = ["title", "width", "height", "fontSize", "transcript", "band",
                 "prompt", "footer", "status"];
  /* The status line as the status bar mod draws it (docs/mods-design.md, "Status bar (#610)"):
     every always-shown fact in the settled order, so a round that names none shows the line Dan
     really has (claude-config#699). The switcher's tests compare it with the design record. */
  var BUILT_STATUS = ["claude-config", "5h 68% (1h 52m)", "week 91% (4d 14h)", "cache 41m",
                      "Opus 5.5 (high)", "Dan, Personal"];

  function refuse(message) { throw new Error("Terminal: " + message); }

  function has(list, value) { return list.indexOf(value) >= 0; }

  function node(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function styleClasses(styles, what) {
    return styles.map(function (s) {
      if (!has(STYLES, s)) {
        refuse('unknown style "' + s + '" on ' + what + ". The styles are " + STYLES.join(", ") + ".");
      }
      return "term-" + s;
    }).join(" ");
  }

  /* One piece of a line: plain text, or something one of the helpers below made. */
  function piece(p) {
    if (typeof p === "string" || typeof p === "number") return document.createTextNode(String(p));
    if (p && p.nodeType === 1) return p;
    refuse("a line can hold text or what a Terminal helper returns, and was given " + JSON.stringify(p) + ".");
  }

  /* run("text", "amber", "bold"): text in one or more styles. */
  function run(text) {
    var styles = Array.prototype.slice.call(arguments, 1);
    return node("span", styleClasses(styles, '"' + text + '"'), String(text));
  }

  function shorthand(style) { return function (text) { return run(text, style); }; }

  /* line(parts, "dim"): a line of pieces, optionally styled as a whole. */
  function line(parts) {
    var styles = Array.prototype.slice.call(arguments, 1);
    var d = node("div", "term-line" + (styles.length ? " " + styleClasses(styles, "a line") : ""));
    (Array.isArray(parts) ? parts : [parts]).forEach(function (p) { d.append(piece(p)); });
    return d;
  }

  /* What a transcript, band or card row may be: a string, an array of pieces, or an element. */
  function row(r) {
    if (typeof r === "string") return line([r]);
    if (Array.isArray(r)) return line(r);
    if (r && r.nodeType === 1) return r;
    refuse("a row is text, a list of pieces or what a Terminal helper returns, and was given " + JSON.stringify(r) + ".");
  }

  function rows(list, what) {
    if (list === undefined || list === null) return [];
    if (!Array.isArray(list)) refuse(what + " is a list of rows.");
    return list.map(row);
  }

  /* button("Switch"): drawn [ Switch ], as Claude Code draws one. {disabled: true} greys it. */
  function button(label, opts) {
    var off = opts && opts.disabled;
    return node("span", off ? "term-button term-button-off" : "term-button", "[ " + label + " ]");
  }

  /* user("words"): what the person typed, as the transcript shows it. */
  function user(text) { return line([run("> ", "grey"), String(text)]); }

  /* card("box" | "rule" | "none", rows, {edge: "amber"}): a group of rows, boxed, ruled down
     its left edge, or neither, so a round about the card's shape names it in one field. */
  function card(kind, list, opts) {
    if (!has(CARDS, kind)) refuse('unknown card "' + kind + '". The cards are ' + CARDS.join(", ") + ".");
    var edge = (opts && opts.edge) || "grey";
    if (!has(EDGES, edge)) refuse('unknown card edge "' + edge + '". The edges are ' + EDGES.join(", ") + ".");
    var c = node("div", "term-card term-card-" + kind + " term-edge-" + edge);
    rows(list, "a card").forEach(function (r) { c.append(r); });
    return c;
  }

  /* divider("violet"): a rule across the band, as a dialog's top edge is drawn. */
  function divider(edge) {
    edge = edge || "grey";
    if (!has(EDGES, edge)) refuse('unknown divider edge "' + edge + '". The edges are ' + EDGES.join(", ") + ".");
    return node("div", "term-divider term-edge-" + edge);
  }

  function size(value, fallback, what) {
    if (value === undefined) return fallback;
    if (typeof value !== "number" || !(value > 0)) refuse(what + " is a number of pixels, and was given " + JSON.stringify(value) + ".");
    return value;
  }

  /* screen({...}): the whole window. The transcript sits at the top; the band, the prompt,
     the footer and the status line sit at the foot, as they do in Claude Code, with the
     space between them taken up. The body has a MINIMUM height, never a fixed one, so a
     band taller than expected grows the window rather than being cut off. */
  function screen(opts) {
    opts = opts || {};
    Object.keys(opts).forEach(function (k) {
      if (!has(OPTIONS, k)) refuse('unknown option "' + k + '". The options are ' + OPTIONS.join(", ") + ".");
    });
    var win = node("div", "term-window");
    win.style.width = size(opts.width, 820, "width") + "px";
    win.style.fontSize = size(opts.fontSize, 13, "fontSize") + "px";

    var bar = node("div", "term-titlebar");
    bar.append(node("span", "term-dot"), node("span", "term-dot"), node("span", "term-dot"),
               node("span", "term-title", opts.title === undefined ? "claude-config" : String(opts.title)));
    win.append(bar);

    var body = node("div", "term-body");
    body.style.minHeight = size(opts.height, 330, "height") + "px";
    rows(opts.transcript, "transcript").forEach(function (r) { body.append(r); });
    body.append(node("div", "term-spacer"));

    var band = rows(opts.band, "band");
    if (band.length) {
      var b = node("div", "term-band");
      band.forEach(function (r) { b.append(r); });
      body.append(b);
    }

    if (opts.prompt !== false) {
      var p = node("div", "term-prompt");
      p.append(run("> ", "grey"), document.createTextNode(opts.prompt === undefined ? "" : String(opts.prompt)),
               node("span", "term-caret", " "));
      body.append(p);
    }

    if (opts.footer !== undefined) {
      var f = row(opts.footer);
      f.classList.add("term-footer");
      body.append(f);
    }

    var status = opts.status === undefined ? BUILT_STATUS : opts.status;
    if (status !== false) {
      if (!Array.isArray(status)) refuse("status is a list of segments, or false for none.");
      var s = node("div", "term-status");
      status.forEach(function (segment) {
        if (typeof segment !== "string" && typeof segment !== "number") {
          refuse("a status segment is text, because the status line is all grey (docs/mods-design.md); " +
                 "a scope mode or anything amber goes in the band. It was given " +
                 (segment && segment.nodeType === 1 ? "a styled run" : JSON.stringify(segment)) + ".");
        }
      });
      // One run of text in the status line's own grey, divided by |, as statusline.sh prints it.
      s.append(document.createTextNode(status.map(String).join(" | ")));
      body.append(s);
    }

    win.append(body);
    return win;
  }

  return {
    screen: screen,
    line: line,
    run: run,
    amber: shorthand("amber"),
    grey: shorthand("grey"),
    red: shorthand("red"),
    violet: shorthand("violet"),
    bold: shorthand("bold"),
    dim: shorthand("dim"),
    white: shorthand("white"),
    button: button,
    user: user,
    card: card,
    divider: divider,
    STYLES: STYLES.slice(),
    CARDS: CARDS.slice(),
    EDGES: EDGES.slice()
  };
})();
