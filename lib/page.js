function main() {
  const data = JSON.parse(document.getElementById("custodian-data").textContent);
  const app = document.getElementById("app");
  const status = document.getElementById("status");
  const WORDS = { fail: "Leak", warn: "Too specific", generic: "Too generic", pass: "In place", accepted: "Accepted", unjudged: "Not yet judged" };
  const DRIFT = {
    changed: "This file changed after it was judged, so the lines below may have moved or gone.",
    relinked: "This file is now loaded from somewhere else, so how far it reaches may have changed.",
    gone: "This file no longer exists.",
  };
  const TIERS = { project: 0, client: 1, global: 2 };
  const picked = new Map();
  const restoring = new Set();
  const unfolded = new Set();
  const FIRST_LINES = 5;
  const view = { node: "", show: new Set(["fail", "warn"]), kind: "", reach: "", q: "", drift: false };
  const narrow = matchMedia("(max-width: 860px)");
  let treeOpen = false;
  let shownLine = "";
  let drawn = false;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }

  function listed(parts) {
    return parts.length < 2 ? parts.join("") : parts.slice(0, -1).join(", ") + " and " + parts[parts.length - 1];
  }

  function readAddress() {
    const params = new URLSearchParams(location.hash.slice(1));
    view.node = params.get("node") || "";
    view.kind = params.get("kind") || "";
    view.reach = params.get("reach") || "";
    view.q = params.get("q") || "";
    view.drift = params.get("drift") === "1";
    if (params.has("show")) view.show = new Set(params.get("show").split(",").filter(Boolean));
  }

  function writeAddress() {
    const params = new URLSearchParams();
    if (view.node) params.set("node", view.node);
    if (view.kind) params.set("kind", view.kind);
    if (view.reach) params.set("reach", view.reach);
    if (view.q) params.set("q", view.q);
    if (view.drift) params.set("drift", "1");
    const show = [...view.show].sort().join(",");
    if (show !== "fail,warn") params.set("show", show);
    history.replaceState(null, "", "#" + params.toString());
  }

  function matches(item) {
    if (view.node && item.node !== view.node && item.top !== view.node) return false;
    if (view.kind && item.kind !== view.kind) return false;
    if (view.reach && item.loaded_by.tier !== view.reach) return false;
    if (view.drift && !item.drift) return false;
    if (!view.q) return true;
    const haystack = [item.id, item.lives_in, item.rationale, ...item.entries.map((e) => (e.text || "") + " " + e.rationale)];
    return haystack.join("\n").toLowerCase().includes(view.q.toLowerCase());
  }

  function ago(timestamp) {
    const hours = (Date.now() - Date.parse(timestamp)) / 36e5;
    if (hours < 1) return "less than an hour ago";
    if (hours < 48) return plural(Math.floor(hours), "hour", "hours") + " ago";
    return plural(Math.floor(hours / 24), "day", "days") + " ago";
  }

  function since() {
    const fresh = data.freshness;
    if (fresh.stale === null) return "What has changed since has not been checked.";
    const parts = [[fresh.changed, "changed"], [fresh.new, "new"], [fresh.gone, "gone"], [fresh.relinked, "loaded from somewhere new"]]
      .filter(([n]) => n).map(([n, word]) => n + " " + word);
    const files = parts.length ? "Since then " + listed(parts) + "." : "Nothing it covers has changed since.";
    return files + (fresh.examples_changed ? " Your examples have changed since." : "") +
      (fresh.roots_changed ? " Your config's roots have changed since." : "") +
      (fresh.judge_changed ? " The model or the accounts in your config have changed since." : "") +
      (fresh.prompt_changed ? " The prompt Custodian judges by has changed since." : "");
  }

  function tone() {
    const days = (Date.now() - Date.parse(data.generated_at)) / 864e5;
    if (days > data.freshness.stale_after_days) return "red";
    return data.freshness.stale ? "amber" : "";
  }

  function report() {
    const head = el("header", "report");
    const { leaks, misfiled, generic, settled, changed, gone } = data.headline;
    const stamp = el("p", "audited");
    stamp.id = "audited";
    head.append(stamp);
    head.append(el("h1", leaks ? "leaking" : "", leaks ? plural(leaks, "file leaks", "files leak") + "." : "Nothing leaks."));
    const accepted = data.summary.acknowledged;
    const sentences = [];
    if (misfiled) sentences.push(plural(misfiled, "file is", "files are") + " too specific for where " + (misfiled === 1 ? "it sits." : "they sit."));
    if (generic) sentences.push(plural(generic, "file is", "files are") + " too generic for where " + (generic === 1 ? "it sits." : "they sit."));
    sentences.push(plural(settled, "file needs", "files need") + " nothing from you" + (accepted ? ", including " + accepted + " you accepted." : "."));
    if (changed) sentences.push(plural(changed, "leaking file has", "leaking files have") + " changed since " + (changed === 1 ? "it was" : "they were") + " judged.");
    if (gone) sentences.push(plural(gone, "judged file has", "judged files have") + " gone, and " + (gone === 1 ? "is" : "are") + " listed apart.");
    head.append(el("p", "", sentences.join(" ")));
    if (data.last_failure) {
      head.append(el("p", "notice", "The last audit did not finish, so this is the report from before it. It said: " +
        data.last_failure.reason.replace(/\.$/, "") + ". Once that is fixed, run /custodian:audit again."));
    }
    return head;
  }

  function stampAge() {
    const stamp = document.getElementById("audited");
    if (!stamp) return;
    const colour = tone();
    stamp.className = "audited " + colour;
    stamp.textContent = "Audited " + ago(data.generated_at) + ". " + since() +
      (colour === "red" ? " It is older than " + plural(data.freshness.stale_after_days, "day", "days") + "." : "") +
      (colour ? " Run the audit again before trusting this." : "");
    if (data.freshness.checked_at) stamp.append(el("span", "checked", " Checked " + ago(data.freshness.checked_at) + "."));
  }

  function tree() {
    const nav = el("nav", "tree");
    nav.setAttribute("aria-label", "Where files live");
    nav.append(el("h2", "", "Where it lives"));
    const fold = el("details", "tree-fold");
    fold.open = !narrow.matches || treeOpen;
    const summary = el("summary", "", "Where it lives");
    summary.dataset.focus = "tree-fold";
    fold.append(summary);
    fold.addEventListener("toggle", () => { if (narrow.matches) treeOpen = fold.open; });
    const list = el("ul");
    list.append(branch({ node: "", label: "Everything", fail: data.everything.fail, warn: data.everything.warn, children: [] }));
    data.tree.forEach((node) => list.append(branch(node)));
    fold.append(list);
    nav.append(fold);
    return nav;
  }

  function branch(node) {
    const row = el("li");
    const button = el("button", "node");
    button.type = "button";
    button.setAttribute("aria-pressed", String(view.node === node.node));
    button.dataset.focus = "node:" + node.node;
    button.append(el("span", "name", node.label));
    button.append(count(node.fail, "leak", "leak", "leaks"), count(node.warn, "misfiled", "too specific", "too specific"));
    button.addEventListener("click", () => {
      view.node = node.node;
      if (narrow.matches) treeOpen = false;
      draw(() => showResults(narrow.matches));
    });
    row.append(button);
    if (node.children && node.children.length) {
      const inner = el("ul");
      node.children.forEach((child) => inner.append(branch(child)));
      row.append(inner);
    }
    return row;
  }

  function count(n, tone, one, many) {
    const span = el("span", "count " + (n ? tone : "none"), String(n));
    span.append(el("span", "sr-only", " " + (n === 1 ? one : many)));
    return span;
  }

  function choice(labelText, value, options, onChange) {
    const label = el("label", "", labelText + " ");
    const select = el("select");
    select.dataset.focus = "choice:" + labelText;
    options.forEach(([optionValue, text]) => {
      const option = el("option", "", text);
      option.value = optionValue;
      select.append(option);
    });
    select.value = value;
    select.addEventListener("change", () => onChange(select.value));
    label.append(select);
    return label;
  }

  function filters(shown, matched) {
    const bar = el("div", "filters");
    [["fail", "Leaks"], ["warn", "Too specific"], ["generic", "Too generic"], ["accepted", "Accepted"], ["pass", "In place"]].forEach(([key, text]) => {
      const label = el("label");
      const box = el("input");
      box.type = "checkbox";
      box.checked = view.show.has(key);
      box.dataset.focus = "show:" + key;
      box.addEventListener("change", () => { box.checked ? view.show.add(key) : view.show.delete(key); draw(); });
      label.append(box, text);
      bar.append(label);
    });
    const changed = el("label");
    const drifted = el("input");
    drifted.type = "checkbox";
    drifted.checked = view.drift;
    drifted.dataset.focus = "drift";
    drifted.addEventListener("change", () => { view.drift = drifted.checked; draw(); });
    changed.append(drifted, "Changed since judged");
    bar.append(changed);
    bar.append(choice("Kind", view.kind, [["", "All"], ["claude_md", "CLAUDE.md"], ["rule", "Rules"], ["skill", "Skills"], ["agent", "Agents"], ["command", "Commands"], ["import", "Imported files"]], (v) => { view.kind = v; draw(); }));
    bar.append(choice("Loaded by", view.reach, [["", "Anything"], ["global", "Every session"], ["client", "One group"], ["project", "One repo"]], (v) => { view.reach = v; draw(); }));
    const search = el("input");
    search.type = "search";
    search.placeholder = "Search ids, paths and reasons";
    search.setAttribute("aria-label", "Search");
    search.value = view.q;
    search.dataset.focus = "search";
    search.addEventListener("input", () => { view.q = search.value; draw(); });
    bar.append(search);
    shownLine = shown + " of " + plural(matched, "file", "files") + " shown";
    bar.append(el("span", "shown", shownLine));
    return bar;
  }

  function loadedBy(item) {
    const by = item.loaded_by;
    if (by.tier === "global") return "every session";
    if (by.tier === "client") return "every session in the " + by.scope + " group";
    return by.scope ? "one repo in the " + by.scope + " group" : "one standalone repo";
  }

  function livesAt(item) {
    if (item.top === "global") return 2;
    if (item.top === "external") return -1;
    return item.node === item.top ? 1 : 0;
  }

  function gauge(item) {
    const loaded = TIERS[item.loaded_by.tier];
    const belongs = item.belongs && item.needs !== "pass" ? TIERS[item.belongs] : loaded;
    const lives = livesAt(item);
    const box = el("div", "gauge");
    box.setAttribute("role", "img");
    box.setAttribute("aria-label", "Loaded by " + loadedBy(item) + (belongs !== loaded ? ". Belongs with " + ["one repo", "one group", "every session"][belongs] : "") + ".");
    [0, 1, 2].forEach((i) => {
      let className = "cell";
      if (i <= loaded) className += i > belongs ? " over" : " loaded";
      else if (i <= belongs) className += " could";
      box.append(el("div", className));
    });
    ["repo", "group", "all"].forEach((word, i) => box.append(el("span", i === lives ? "lives" : "", word)));
    return box;
  }

  function copy(text, button, done) {
    const finish = () => {
      const was = button.textContent;
      button.textContent = done;
      status.textContent = done;
      setTimeout(() => { button.textContent = was; }, 1600);
    };
    const fallback = () => {
      const area = el("textarea");
      area.value = text;
      document.body.append(area);
      area.select();
      document.execCommand("copy");
      area.remove();
      finish();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(finish, fallback);
    else fallback();
  }

  function editorAddress(path, line) {
    if (!data.editor_url) return "";
    const address = data.editor_url.replace("{path}", () => encodeURI(path)).replace("{line}", () => String(line));
    return /^(https?|javascript|data|vbscript|blob):/i.test(address) ? "" : address;
  }

  function entryRow(item, entry) {
    const accepted = entry.acknowledged !== null;
    const which = item.id + (entry.line ? ", line " + entry.line : ", whole file");
    const row = el("li", "entry " + (accepted ? "accepted" : entry.verdict));
    row.append(el("span", "line", entry.line ? "line " + entry.line : "whole file"));
    if (entry.text) {
      const quote = el("code", "", entry.text);
      quote.dir = "auto";
      row.append(quote);
    } else row.append(el("span", "", "Judged as a whole file, not line by line."));
    if (item.by_line) row.append(el("p", "", entry.rationale));
    const tools = el("div", "tools");

    const label = el("label");
    const box = el("input");
    box.type = "checkbox";
    box.dataset.focus = "entry:" + entry.key;
    const note = el("input");
    note.dataset.focus = "note:" + entry.key;
    note.type = "text";
    note.maxLength = 500;
    note.placeholder = "Why this is fine (optional)";
    note.setAttribute("aria-label", "Note on " + which);
    if (accepted) {
      box.checked = restoring.has(entry.key);
      box.addEventListener("change", () => { box.checked ? restoring.add(entry.key) : restoring.delete(entry.key); saveBar(); });
      box.setAttribute("aria-label", "Stop accepting this: " + which);
      label.append(box, "Stop accepting this");
      tools.append(el("span", "note", "Accepted " + entry.acknowledged.acknowledged_at.slice(0, 10) + (entry.acknowledged.note ? ": " + entry.acknowledged.note : "")));
      tools.append(label);
    } else {
      box.checked = picked.has(entry.key);
      note.value = picked.get(entry.key) || "";
      note.hidden = !box.checked;
      box.addEventListener("change", () => {
        if (box.checked) picked.set(entry.key, note.value); else picked.delete(entry.key);
        note.hidden = !box.checked;
        saveBar();
      });
      note.addEventListener("input", () => { if (picked.has(entry.key)) picked.set(entry.key, note.value); saveBar(); });
      box.setAttribute("aria-label", "Accept as intended: " + which);
      label.append(box, "Accept as intended");
      tools.append(label, note);
    }

    const where = item.lives_in + (entry.line ? ":" + entry.line : "");
    const copyPath = el("button", "", "Copy path");
    copyPath.type = "button";
    copyPath.dataset.focus = "copy:" + entry.key;
    copyPath.setAttribute("aria-label", "Copy path of " + which);
    copyPath.addEventListener("click", () => copy(where, copyPath, "Copied"));
    tools.append(copyPath);
    const address = editorAddress(item.path, entry.line || 1);
    if (address) {
      const link = el("a", "", "Open in editor");
      link.href = address;
      link.dataset.focus = "editor:" + entry.key;
      link.setAttribute("aria-label", "Open in editor: " + which);
      tools.append(link);
    }
    row.append(tools);
    return row;
  }

  function places(body, lead, list, one, many) {
    if (!list.length) return;
    const links = el("details", "links");
    links.append(el("summary", "", lead + plural(list.length, one, many)));
    const rows = el("ul");
    list.forEach((place) => rows.append(el("li", "", place)));
    links.append(rows);
    body.append(links);
  }

  function card(item) {
    const which = item.band;
    const row = el("article", "item");
    const verdict = el("div", "verdict " + which, WORDS[which]);
    verdict.append(el("small", "", { claude_md: "CLAUDE.md", rule: "rule", skill: "skill", agent: "agent", command: "command", import: "imported file" }[item.kind]));
    row.append(verdict);

    const body = el("div");
    body.append(el("h3", "", item.id));
    const where = el("p", "where", "Lives in ");
    const copyHome = el("button", "copy", "Copy");
    copyHome.type = "button";
    copyHome.dataset.focus = "home:" + item.id;
    copyHome.setAttribute("aria-label", "Copy path of " + item.id);
    copyHome.addEventListener("click", () => copy(item.lives_in, copyHome, "Copied"));
    where.append(el("code", "", item.lives_in), " ", copyHome, ". Loaded by " + loadedBy(item) + ".");
    if (item.belongs && which !== "accepted") {
      where.append(" ", el("span", "move", "Belongs with " + ["one repo", "one group", "every session"][TIERS[item.belongs]] + "."));
    }
    body.append(where);
    if (DRIFT[item.drift]) body.append(el("p", "drifted", DRIFT[item.drift]));
    places(body, "Linked from ", item.linked_from, "place", "places");
    places(body, "Imported by ", item.imported_by, "file", "files");
    places(body, "Sits above ", item.above, "root", "roots");
    body.append(el("p", "reason", item.rationale));
    row.append(body, gauge(item));

    const entries = el("ul", "entries");
    item.entries.slice(0, FIRST_LINES).forEach((entry) => entries.append(entryRow(item, entry)));
    row.append(entries);
    if (item.entries.length > FIRST_LINES) row.append(moreLines(item));
    return row;
  }

  function moreLines(item) {
    const more = el("details", "more");
    more.open = unfolded.has(item.id);
    const summary = el("summary", "", plural(item.entries.length - FIRST_LINES, "more flagged line", "more flagged lines"));
    summary.dataset.focus = "more:" + item.id;
    more.append(summary);
    const rest = el("ul", "entries");
    item.entries.slice(FIRST_LINES).forEach((entry) => rest.append(entryRow(item, entry)));
    more.append(rest);
    more.addEventListener("toggle", () => { if (more.open) unfolded.add(item.id); else unfolded.delete(item.id); });
    return more;
  }

  function fold(title, items) {
    const box = el("details", "fold");
    box.append(el("summary", "", title));
    items.forEach((item) => {
      const row = el("div", "plain");
      row.append(el("span", "", item.id), el("span", "", item.lives_in));
      box.append(row);
    });
    return box;
  }

  function orphans() {
    const box = el("details", "fold");
    box.append(el("summary", "", "Accepted, but no longer flagged (" + data.orphaned_acknowledgements.length + ")"));
    data.orphaned_acknowledgements.forEach((orphan) => {
      const row = el("div", "plain");
      const label = el("label");
      const tick = el("input");
      tick.type = "checkbox";
      tick.checked = restoring.has(orphan.key);
      tick.dataset.focus = "orphan:" + orphan.key;
      tick.addEventListener("change", () => { tick.checked ? restoring.add(orphan.key) : restoring.delete(orphan.key); saveBar(); });
      label.append(tick, " Stop accepting " + orphan.id);
      row.append(label, el("span", "", orphan.note || "No note"));
      box.append(row);
    });
    return box;
  }

  function payload() {
    const body = { v: 1, ack: [...picked].map(([key, note]) => ({ key, note })), restore: [...restoring] };
    const bytes = new TextEncoder().encode(JSON.stringify(body));
    let binary = "";
    bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function saveBar() {
    const bar = document.getElementById("save");
    bar.replaceChildren();
    bar.hidden = picked.size + restoring.size === 0;
    if (bar.hidden) return;
    const parts = [];
    if (picked.size) parts.push(picked.size + " to accept");
    if (restoring.size) parts.push(restoring.size + " to stop accepting");
    bar.append(el("strong", "", parts.join(", ")));
    const command = data.ack_command + " " + payload();
    const terminal = el("button", "", "Copy save command");
    terminal.type = "button";
    terminal.addEventListener("click", () => copy(command, terminal, "Copied"));
    const claude = el("button", "second", "Copy for Claude Code");
    claude.type = "button";
    claude.addEventListener("click", () => copy("/custodian:ack " + payload(), claude, "Copied"));
    const field = el("input");
    field.readOnly = true;
    field.value = command;
    field.setAttribute("aria-label", "Save command");
    bar.append(terminal, claude, field);
    bar.append(el("span", "hint", "This page cannot save for you. Paste the copied command into a terminal or into Claude Code, then refresh this page."));
  }

  function ledger() {
    const main = el("main", "ledger");
    main.id = "results";
    main.tabIndex = -1;
    const matched = data.items.filter(matches);
    const visible = matched.filter((item) => item.drift !== "gone");
    const gone = matched.filter((item) => item.drift === "gone");
    const fresh = data.unjudged.filter(matches);
    const open = visible.filter((item) => ["fail", "warn"].includes(item.band) && view.show.has(item.band));
    const generic = visible.filter((item) => item.band === "generic");
    const accepted = visible.filter((item) => item.band === "accepted");
    const settled = visible.filter((item) => item.band === "pass");
    main.append(el("p", "legend", "The three bars show how far a file is loaded: one repo, its group, or every session. Red is further than its content belongs, a dashed bar is how far it could go, and the underlined word is where the file lives."));
    open.forEach((item) => main.append(card(item)));
    if (view.show.has("generic")) generic.forEach((item) => main.append(card(item)));
    if (fresh.length) {
      main.append(el("h2", "band", "Not yet judged"));
      fresh.forEach((item) => main.append(card(item)));
    }
    if (view.show.has("accepted")) accepted.forEach((item) => main.append(card(item)));
    if (!open.length && !fresh.length && !(view.show.has("generic") && generic.length) && !(view.show.has("accepted") && accepted.length)) {
      const nothing = !matched.length;
      const empty = el("p", "empty", nothing ? "Nothing matches these filters. " : "Nothing here needs you. ");
      const clear = el("button", "clear", "Clear filters");
      clear.type = "button";
      clear.addEventListener("click", () => {
        Object.assign(view, { node: "", kind: "", reach: "", q: "", drift: false });
        view.show = new Set(["fail", "warn"]);
        draw(() => app.querySelector('[data-focus="search"]').focus());
      });
      if (nothing) empty.append(clear);
      main.append(empty);
    }
    if (!view.show.has("generic") && generic.length) main.append(fold("Too generic (" + generic.length + ")", generic));
    if (!view.show.has("accepted") && accepted.length) main.append(fold("Accepted (" + accepted.length + ")", accepted));
    if (view.show.has("pass")) settled.forEach((item) => main.append(card(item)));
    else if (settled.length) main.append(fold("In place (" + settled.length + ")", settled));
    if (gone.length) main.append(fold("Gone since the audit (" + gone.length + ")", gone));
    if (data.orphaned_acknowledgements.length) main.append(orphans());
    main.prepend(filters(main.querySelectorAll("article.item").length, matched.length + fresh.length));
    return main;
  }

  function showResults(moveFocus) {
    const main = document.getElementById("results");
    const top = main.getBoundingClientRect().top;
    if (moveFocus) main.focus({ preventScroll: true });
    if (moveFocus || top < 0 || top > innerHeight * 0.6) main.scrollIntoView({ block: "start" });
  }

  function skipLink() {
    const link = el("a", "skip", "Skip to results");
    link.href = "#results";
    link.dataset.focus = "skip";
    link.addEventListener("click", (event) => { event.preventDefault(); showResults(true); });
    return link;
  }

  function draw(after) {
    const active = document.activeElement;
    const focused = active && active.dataset ? active.dataset.focus : undefined;
    const caret = active && active.type === "search" ? active.selectionStart : null;
    writeAddress();
    const desk = el("div", "desk");
    desk.append(tree(), ledger());
    const bar = el("div", "save");
    bar.id = "save";
    bar.hidden = true;
    const foot = el("footer", "", "This page is a file on your disk and cannot connect to anything. Judged by " + data.model + " through Claude Code " + data.claude_code_version + ".");
    app.replaceChildren(skipLink(), report(), desk, foot, bar);
    stampAge();
    saveBar();
    const again = focused && app.querySelector('[data-focus="' + CSS.escape(focused) + '"]');
    if (again) {
      again.focus({ preventScroll: true });
      if (caret !== null) again.setSelectionRange(caret, caret);
    }
    if (drawn) status.textContent = shownLine;
    drawn = true;
    if (after) after();
  }

  readAddress();
  draw();
  window.addEventListener("hashchange", () => { readAddress(); draw(); });
  narrow.addEventListener("change", () => draw());
  setInterval(stampAge, 60000);
}

main();
