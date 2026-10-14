# What an import is. The awk below reads a file as the Markdown lexer inside Claude Code does, and follows an import only where that lexer has text.
IMPORT_DEPTH=4
# The file types Claude Code 2.1.296 was seen to import. A file of any other type is never sent to a session.
IMPORT_EXTENSIONS="adoc bash bat c cc cfg cjs clj cmake cmd conf config cpp cs css csv cts dart diff env erl ex exs fish go gql gradle graphql h hpp hs htm html ini java js json jsx kt kts less lock log lua md mjs mts org patch php pl properties proto ps1 py pyi r rb rs rst sass scala scss sh sql svelte swift tex text toml ts tsx txt vue xml yaml yml zsh"

# Where it cannot follow the lexer for certain it sets lost and reads no further; inside a paragraph it stops where a span, a tag or a link could hide what comes next.
IMPORT_AWK='
BEGIN {
  UWS = "\302\240|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200|\357\273\277"
  WS = "[ \t\v\f\r]|" UWS
  WS1 = "^(" WS ")"; WSLEAD = "^(" WS ")+"; WSEND = "(" WS ")+$"; JSB = "^(" WS ")*$"; LABELB = "^(" WS "|\n)*$"
  ODD = "[\v\f\r]|" UWS; FRONT = "^---(" WS ")*$"
  DIG = "[0-9][0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?"
  MARK = "^ ? ? ?([*+-]|" DIG "[.)])"
  LIST = MARK "([ \t].+)?$"
  BULLET = "^([*+-]|" DIG "[.)])([ \t]|$)"; BULLETSP = "^([*+-]|" DIG "[.)]) "
  TAGS = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
  PHTML = "^(</?(" TAGS ")( |/?>)|<(script|pre|style|textarea|!--))"; PHTMLEOL = "^</?(" TAGS ")$"
  H1 = "^<(script|pre|style|textarea)(>|" WS ")"
  H6 = "^</?(" TAGS ")( |/?>)"; H6EOL = "^</?(" TAGS ")$"
  H7 = "^<[a-z][a-z0-9_-]*( +[a-z:_][a-z0-9_.:-]*( *= *\"[^\"]*\"| *= *\047[^\047]*\047| *= *[^ \t\"\047=<>`]+)?)* */?>[ \t]*$"
  H7S = "^<[a-z][a-z0-9_-]*( +[a-z:_][a-z0-9_.:-]*( *= *\"[^\"]*\"| *= *\047[^\047]*\047| *= *[^ \t\v\f\"\047=<>`\200-\377]+)?)* */?>[ \t]*$"
  C7 = "^</[a-z][a-z0-9_-]*(" WS ")*>[ \t]*$"; C7OPEN = "^</[a-z][a-z0-9_-]*(" WS ")*$"; C7END = "^(" WS ")*>[ \t]*$"
  CTAG = "^/[A-Za-z][A-Za-z0-9_:-]*[ \t\003]*>"
  ITAG = "^[A-Za-z][A-Za-z0-9_-]*([ \t\003]+[A-Za-z:_][A-Za-z0-9_.:-]*([ \t\003]*=[ \t\003]*(\"[^\"]*\"|\047[^\047]*\047|[^ \t\003\"\047=<>`]+))?)*[ \t\003]*/?>"
  AUTO = "^[A-Za-z][A-Za-z0-9+.-]+:[^ <>\001-\037]*>"
}

function lead(s) { match(s, /^ */); return RLENGTH }
function blank(s) { return s ~ /^[ \t]*$/ }
function jsblank(s) { return s ~ JSB }
function detab(s) { gsub(/\t/, "    ", s); return s }
function mirror(s,   r, k) { for (k = length(s); k > 0; k--) r = r substr(s, k, 1); return r }
function glue(arr, lo, hi, sep,   mid) {
  if (lo > hi) return ""
  if (lo == hi) return arr[lo]
  mid = int((lo + hi) / 2)
  return glue(arr, lo, mid, sep) sep glue(arr, mid + 1, hi, sep)
}

function emit(token,   name, ext) {
  gsub(/\\ /, " ", token)
  sub(/#.*$/, "", token)
  if (token !~ /^(\.\/|~\/|\/.|[A-Za-z0-9._-])/) return
  name = token
  sub(/^.*\//, "", name)
  sub(/^\./, "", name)
  ext = ""
  if (name ~ /\.$/) ext = "."
  else if (match(name, /\.[^.]*$/)) ext = tolower(substr(name, RSTART + 1))
  out[++no] = token "\t" ext
}

# Only one-character separators split anything here: this awk takes quadratic time to split on a pattern.
function scan(piece, first, lit, raw, em,   n, part, i, j, prev, open, shut, seg, size, token, ended, p) {
  n = split(piece, part, "@")
  i = 2
  while (i <= n) {
    prev = part[i - 1]; open = ""
    if (em && match(prev, /[*_]+$/)) { open = substr(prev, RSTART); prev = substr(prev, 1, RSTART - 1) }
    if (!((prev == "" && i == 2 && first) || prev ~ /[ \t\003\v\f\002]$/)) { i++; continue }
    token = ""; j = i
    while (1) {
      seg = part[j]
      size = match(seg, /^([^ \t\003\v\f\\]|\\ )+/) ? RLENGTH : 0
      token = token substr(seg, 1, size)
      if (size < length(seg) || j >= n) break
      token = token "@"; j++
    }
    ended = (size == length(seg))
    if (match(token, UWS)) { token = substr(token, 1, RSTART - 1); ended = 0 }
    if (!raw) {
      if (match(token, /[\001\002]/)) { token = substr(token, 1, RSTART - 1); ended = 0 }
      if (open != "") {
        shut = mirror(open); p = length(token) - length(shut)
        token = (p > 0 && substr(token, p + 1) == shut) ? substr(token, 1, p) : ""
      }
      if (token ~ /[*[<]/ || token ~ /(^|[^A-Za-z0-9_])_/ || token ~ /_([^A-Za-z0-9_]|$)/ || (ended && lit)) token = ""
    }
    emit(token)
    i = j + 1
  }
}

# \001 stands for hidden text, \002 for hidden text that a new run of text starts after, \003 for a line break.
function links(V, first, more, lit,   n, piece, k, s, m, v, p, ok) {
  ok = !(more && substr(V, length(V)) == "\\")
  if (index(V, "[") == 0) { scan(V, first, lit || !ok, 0, emok); return ok }
  n = split(V, piece, "]"); m = 0
  for (k = 1; k <= n; k++) {
    s = piece[k]
    if (k > 1) {
      if (s ~ /^\(/) {
        if (match(s, /^\([ \t\003]*[^ \t\003()<>"\047\\\001\002]*[ \t\003]*\)/)) s = "\001" substr(s, RLENGTH + 1)
        else if (more || k < n || index(s, ")")) { ok = 0; break }
      } else if (s ~ /^\[/) {
        if (k == n || substr(s, 2) ~ /[[\\\001\002]/) { ok = 0; break }
        v[++m] = "]\001"; continue
      }
      s = "]" s
    }
    if ((p = index(s, "![")) && (k < n || more)) {
      if (k == n || substr(s, p + 2) ~ /[[\\\001\002]/) { v[++m] = substr(s, 1, p - 1); ok = 0; break }
      s = substr(s, 1, p - 1) "\001"
    }
    v[++m] = s
  }
  if (ok && more && index(piece[n], "[")) ok = 0
  scan(glue(v, 1, m, ""), first, lit || !ok, 0, emok)
  return ok
}

function visible(C, first, more, lit,   n, piece, p, s, q, t, v, m, end, skip) {
  if (index(C, "<") == 0) return links(C, first, more, lit)
  n = split(C, piece, "<"); m = 0; v[++m] = piece[1]
  for (p = 2; p <= n; p++) {
    s = piece[p]
    if (s ~ ODD) break
    if (match(s, /^!---?>/)) { v[++m] = "\002" substr(s, RLENGTH + 1); continue }
    end = ""
    if (s ~ /^!--/) { end = "-->"; skip = 3 }
    else if (s ~ /^\?/) { end = "?>"; skip = 1 }
    else if (s ~ /^!\[CDATA\[/) { end = "]]>"; skip = 8 }
    else if (match(s, /^![A-Za-z]+[ \t\003]/)) { end = ">"; skip = RLENGTH }
    if (end != "") {
      if (q = index(substr(s, skip + 1), end)) { v[++m] = "\002" substr(s, skip + q + length(end)); continue }
      for (t = p + 1; t <= n; t++) if (q = index(piece[t], end)) break
      if (t <= n) { v[++m] = "\002" substr(piece[t], q + length(end)); p = t; continue }
      if (more) break
      v[++m] = "<" s; continue
    }
    if (match(s, CTAG) || match(s, ITAG) || (match(s, AUTO) && index(s, ":") > 2 && index(s, ":") < 34)) { v[++m] = "\002" substr(s, RLENGTH + 1); continue }
    if ((s ~ /^[A-Za-z]/ && s ~ /["\047]/) || s ~ /^[^ \t\003>@]*@[^ \t\003>]*>/ || (p == n && more && s ~ /^[^ \t\003>]*$/)) break
    v[++m] = "<" s
  }
  if (p <= n) { links(glue(v, 1, m, ""), first, 1, 1); return 0 }
  return links(glue(v, 1, m, ""), first, more, lit)
}

function inline(P,   n, seg, c, i, j, r, k, text, run, shut, nx, first) {
  n = split(P, seg, "`"); c = 0; i = 1
  while (1) {
    text[++c] = seg[i]
    if (i >= n) break
    r = 1
    for (j = i + 1; j < n && seg[j] == ""; j++) r++
    run[c] = r; i = j
  }
  for (k = c - 1; k >= 1; k--) { shut[k] = nx[run[k]]; nx[run[k]] = k }
  k = 1; first = 1
  while (1) {
    if (!visible(text[k], first, k < c, k < c && !shut[k]) || k >= c) return
    first = (shut[k] != "")
    k = first ? shut[k] + 1 : k + 1
  }
}

function add(tl, s) { A[tl, ++an[tl]] = s }
function flush(tl,   n, k, plain, v, P) {
  n = an[tl]; an[tl] = 0
  if (!n || lost) return
  if (ak[tl] == "t") for (k = 1; k <= n; k++) scan(A[tl, k], 1, 0, 1, 0)
  plain = 1
  for (k = 1; k <= n && plain; k++) if (A[tl, k] ~ /[`<[]/) plain = 0
  if (plain) { for (k = 1; k <= n; k++) scan(A[tl, k], 1, 0, 0, 1); return }
  for (k = 1; k <= n; k++) v[k] = A[tl, k]
  P = glue(v, 1, n, "\003")
  # The lexer looks for emphasis with spans, tags and links blanked out, so a mark inside one of those is no mark to it.
  emok = !(P ~ /\\|`[^`]*[*_][^`]*`|<[^<>]*[*_][^<>]*>|\[[^][]*[*_][^][]*\]|\]\(.*[*_].*\)/)
  inline(P)
}
function push(tl, type) { flush(tl); lastt[tl] = type }
function fresh(   tl) { tl = ++ntl; lastt[tl] = ""; an[tl] = 0; return tl }

function fencerun(s,   t) {
  if (s !~ /^ ? ? ?(```|~~~)/) return ""
  t = s; sub(/^ +/, "", t)
  match(t, /^(`+|~+)/)
  if (substr(t, 1, 1) == "`" && index(substr(t, RLENGTH + 1), "`")) return ""
  return substr(t, 1, RLENGTH)
}
function closes(s, run,   t) {
  if (s !~ /^ ? ? ?[`~]/) return 0
  t = s; sub(/^ +/, "", t)
  return substr(t, 1, length(run)) == run && substr(t, length(run) + 1) ~ /^[`~]* *$/
}
function hr(s) { return s ~ /^ ? ? ?(-[\t ]*-[\t ]*-[\t -]*|_[\t ]*_[\t ]*_[\t _]*|\*[\t ]*\*[\t ]*\*[\t *]*)$/ }
function heading(s,   t) {
  if (s !~ /^ ? ? ?#/) return 0
  t = s; sub(/^ +/, "", t); match(t, /^#+/)
  if (RLENGTH > 6) return 0
  t = substr(t, RLENGTH + 1)
  return t == "" || t ~ WS1
}
function interrupts(s, eol) {
  if (s == "" || hr(s) || heading(s) || s ~ /^ ? ? ?>/ || s ~ /^ ? ? ?([*+-]|1[.)]) / || s ~ PHTML) return 1
  return eol && (s ~ /^ +$/ || fencerun(s) != "" || s ~ PHTMLEOL)
}

function htmlkind(b, i, eol,   low, j) {
  htmlmore = 0
  if (B[b, i] !~ /^ ? ? ?</) return 0
  low = tolower(B[b, i]); sub(/^ +/, "", low)
  if (low ~ H1 || (eol && low ~ /^<(script|pre|style|textarea)$/)) return 1
  if (low ~ /^<!--/) return 2
  if (low ~ /^<\?/) return 3
  if (low ~ /^<![a-z]/) return 4
  if (low ~ /^<!\[cdata\[/) return 5
  if (low ~ H6) return 6
  # A tag name at the end of its line takes the line break with it, so a blank line straight after does not end the block.
  if (eol && low ~ H6EOL) { htmlmore = 1; return 6 }
  if (low ~ /^<\/?(script|pre|style|textarea)/) return 0
  if (low ~ H7) {
    if (low !~ ODD || low ~ H7S) return 7
    lost = 1; return 0
  }
  if (low ~ C7) return 7
  if (low !~ C7OPEN) return 0
  for (j = i + 1; j <= N[b] && jsblank(B[b, j]); j++) ;
  if (j > N[b] || B[b, j] !~ C7END) return 0
  htmlmore = j - i
  return 7
}
function html(b, i, kind,   n, s, low, j, p, off, name, end, rest) {
  n = N[b]; s = B[b, i]
  if (kind == 1) {
    low = tolower(s); match(low, /<(script|pre|style|textarea)/)
    name = "</" substr(low, RSTART + 1, RLENGTH - 1) ">"; low = substr(low, RSTART + RLENGTH + 1)
    for (j = i; j <= n; j++) { if (j > i) low = tolower(B[b, j]); if (index(low, name)) break }
  } else if (kind == 2) {
    rest = substr(s, index(s, "<!--") + 4)
    if (rest ~ /^-?>/) { j = i; p = index(rest, "-->"); rest = p ? substr(rest, p + 3) : s }
    else {
      for (j = i; j <= n; j++) { if (j > i) rest = B[b, j]; if (p = index(rest, "-->")) break }
      rest = substr(rest, p + 3)
    }
    if (j <= n) { gsub(/<!--([^-]|-[^-]|--+[^->])*-*-->/, "", rest); scan(rest, 1, 0, 1, 0) }
  } else if (kind < 6) {
    end = (kind == 3) ? "?>" : (kind == 4) ? ">" : "]]>"
    off = index(s, "<") - 1 + ((kind == 3) ? 2 : (kind == 4) ? 3 : 9); rest = substr(s, off + 1)
    for (j = i; j <= n; j++) { if (j > i) { rest = B[b, j]; off = 0 } if (p = index(rest, end)) break }
    if (j > n) return n + 1
    rest = substr(rest, p + length(end))
    if (rest != "") { B[b, j] = rest; return j }
  } else {
    for (j = i + htmlmore + 1; j <= n && !blank(B[b, j]); j++) ;
    while (j <= n && blank(B[b, j])) j++
    return j
  }
  for (j++; j <= n && B[b, j] == ""; j++) ;
  return j
}

function bracket(s,   off) {
  off = 0
  while (match(s, /[][\\]/)) {
    if (substr(s, RSTART, 1) != "\\") return off + RSTART
    if (RSTART == length(s)) return -1
    off += RSTART + 1; s = substr(s, RSTART + 2)
  }
  return 0
}
function title(b, l, t,   n, c, r, p, nc, cl, cok, k, far) {
  n = N[b]; c = substr(t, 1, 1); r = substr(t, 2); far = l + 200; nc = 0
  while (1) {
    if (c == "(") {
      if (p = match(r, /[()]/)) return (substr(r, p, 1) == ")" && substr(r, p + 1) ~ /^ *$/) ? l : 0
    } else if (c == "\047") {
      if (p = index(r, "\047")) return substr(r, p + 1) ~ /^ *$/ ? l : 0
      if (l < n && B[b, l + 1] == "") return 0
    } else {
      while (match(r, /[\\"]/)) {
        if (substr(r, RSTART, 1) == "\"") {
          if (substr(r, RSTART + 1) ~ /^ *$/) return l
          for (k = nc; k >= 1; k--) if (cok[k]) return cl[k]
          return 0
        }
        if (substr(r, RSTART + 1, 1) == "\"") { cl[++nc] = l; cok[nc] = (substr(r, RSTART + 2) ~ /^ *$/); r = substr(r, RSTART + 2) }
        else r = substr(r, RSTART + 1)
      }
    }
    if (++l > n) break
    if (l > far) { lost = 1; return 0 }
    r = B[b, l]
  }
  for (k = nc; k >= 1; k--) if (cok[k]) return cl[k]
  return 0
}
function deftail(b, j, after,   t, l, e) {
  l = 0
  if (after ~ /^ +["\047(]/) { t = after; sub(/^ +/, "", t); l = j }
  else if (after ~ /^ *$/ && j < N[b]) { t = B[b, j + 1]; sub(/^[ \t]+/, "", t); if (t ~ /^["\047(]/) l = j + 1 }
  if (l && (e = title(b, l, t))) return e
  return after ~ /^ *$/ ? j : 0
}
function def(b, i,   n, j, p, lab, rest, r, k, e) {
  n = N[b]
  if (B[b, i] !~ /^ ? ? ?\[/) return 0
  rest = B[b, i]; sub(/^ *\[/, "", rest); lab = ""; j = i
  while (!(p = bracket(rest))) {
    lab = lab rest "\n"
    if (++j > n) return 0
    rest = B[b, j]
  }
  if (p < 0 || substr(rest, p, 2) != "]:") return 0
  lab = lab substr(rest, 1, p - 1)
  if (lab ~ LABELB) return 0
  rest = substr(rest, p + 2); sub(/^ +/, "", rest)
  if (rest == "") { if (++j > n) return 0; rest = B[b, j]; sub(/^[ \t]+/, "", rest) }
  if (rest == "" || rest ~ WS1) return 0
  e = 0
  if (substr(rest, 1, 1) == "<") {
    r = substr(rest, 2); k = 1
    while (!e && (p = index(r, ">"))) { k += p; e = deftail(b, j, substr(rest, k + 1)); r = substr(r, p + 1) }
  } else e = deftail(b, j, match(rest, WS) ? substr(rest, RSTART) : "")
  if (!e || lost) return 0
  for (e++; e <= n && B[b, e] == ""; e++) ;
  return e - i
}

function lhstop(s, eol) {
  return s ~ BULLETSP || s ~ /^(    | ? ? ?\t)/ || s ~ /^ ? ? ?(```|~~~|>|#)/ || (eol && s ~ /^ ? ? ?<[^>]+>$/)
}
function lheading(b, i,   n, j, s) {
  n = N[b]
  if (i < lhfail[b] || lhstop(B[b, i], i < n || !b)) return 0
  for (j = i + 1; j <= n; j++) {
    s = B[b, j]
    if (s ~ /^ ? ? ?(=+|-+) *$/) return j - i + 1
    if (jsblank(s) || lhstop(s, j < n || !b)) break
  }
  lhfail[b] = j
  return 0
}

function pre(indent, s,   k) {
  k = lead(s)
  return k <= (indent > 4 ? 3 : indent - 1) ? substr(s, k + 1) : "\001"
}
function linebreak(indent, s) {
  s = pre(indent, s)
  return s ~ /^(```|~~~|#)/ || s ~ /^(- *- *-[ -]*|_ *_ *_[ _]*|\* *\* *\*[ *]*)$/
}
function itembreak(indent, s,   t) {
  t = pre(indent, s)
  return linebreak(indent, s) || tolower(t) ~ /^<([a-z].*>|!--)/ || t ~ BULLET
}
function item(c, final,   tl) {
  if (final) { while (N[c] > 0 && jsblank(B[c, N[c]])) N[c]--; if (N[c]) sub(WSEND, "", B[c, N[c]]) }
  tl = fresh(); top = 0
  blocks(c, tl, 0); flush(tl)
}
function list(b, i,   n, s, ord, bull, start, last, cap1, cap2, line, bl, indent, c, m, nl, nlt, t, pc) {
  n = N[b]; start = i; s = B[b, i]
  ord = (s ~ /^ *[0-9]/); match(s, /^ *([*+-]|[0-9]+[.)])/); bull = substr(s, RLENGTH, 1)
  pc = 0; last = i
  while (i <= n && !lost) {
    s = B[b, i]
    if (s !~ ("^ ? ? ?" (ord ? DIG : "") "[" bull "]([ \t]|$)") || hr(s)) break
    if (pc) item(pc, 0)
    match(s, /^ *([*+-]|[0-9]+[.)])/); cap1 = RLENGTH; cap2 = substr(s, RLENGTH + 1)
    line = cap2
    if (match(line, /^\t+/)) line = sprintf("%" (3 * RLENGTH) "s", "") substr(line, RLENGTH + 1)
    bl = jsblank(line); c = ++nb; m = 0
    if (bl) { indent = cap1 + 1; B[c, ++m] = "" }
    else {
      indent = lead(cap2)
      # More than four spaces after the mark is code, and the lexer then starts the item one column in.
      if (indent > 4) indent = 1
      B[c, ++m] = substr(line, indent + 1); indent += cap1
    }
    last = i++
    if (bl && (i > n || blank(B[b, i]))) i++
    else for (; i <= n; i++) {
      nl = B[b, i]; nlt = detab(nl)
      if (itembreak(indent, nl)) break
      if ((nlt ~ /[^ ]/ && lead(nlt) >= indent) || jsblank(nl)) B[c, ++m] = substr(nlt, indent + 1)
      else {
        t = detab(line)
        if (bl || (t ~ /[^ ]/ && lead(t) >= 4) || linebreak(indent, line)) break
        B[c, ++m] = nl
      }
      if (jsblank(nl)) bl = 1; else last = i
      line = substr(nlt, indent + 1)
    }
    N[c] = m; pc = c
  }
  if (pc) item(pc, 1)
  return last - start + 1
}

function quote(b, i,   n, j, k, c, m, s, inq, qtl, save) {
  n = N[b]
  for (j = i; j <= n && B[b, j] ~ /^ ? ? ?>/; ) {
    s = B[b, j++]; sub(/^ *> ?/, "", s)
    if (s != "") while (j <= n && !interrupts(B[b, j], j < n || !b)) j++
  }
  qtl = fresh(); k = i
  while (k < j && !lost) {
    c = ++nb; m = 0; inq = 0
    for (; k < j; k++) {
      s = B[b, k]
      if (s ~ /^ ? ? ?>/) { inq = 1; sub(/^ *>[ \t]?/, "", s) }
      else if (inq) break
      else if (m && s ~ /^ ? ? ?(=+|-+) *$/) { sub(/^ */, "", s); s = "    " s }
      B[c, ++m] = s
    }
    N[c] = m
    save = top; top = 1; blocks(c, qtl, 1); top = save
    if (k >= j || lastt[qtl] == "code") break
    # A lazy line after a list or a quote sends the lexer back over it, and where it then stops turns on lengths this does not keep.
    if (lastt[qtl] == "list" || lastt[qtl] == "blockquote") { no = mark[qtl]; lost = 1 }
  }
  flush(qtl)
  return k - i
}

function blocks(b, tl, clipped,   n, i, j, k, s, t, run, kind) {
  # Claude Code drops a file whose nesting overflows the lexer, so past this depth nothing the file named is kept.
  if (++depth > 60) lost = deep = 1
  n = N[b]; i = 1
  while (i <= n && !lost) {
    s = B[b, i]
    if (blank(s)) { while (i <= n && blank(B[b, i])) i++; push(tl, "space"); continue }
    if (s ~ /^(    | ? ? ?\t)/) {
      j = i
      while (1) {
        for (k = j + 1; k <= n && blank(B[b, k]); k++) ;
        if (k <= n && B[b, k] ~ /^(    | ? ? ?\t)/) j = k; else break
      }
      if (lastt[tl] == "paragraph" || lastt[tl] == "text") for (t = i; t <= j; t++) add(tl, B[b, t])
      else push(tl, "code")
      i = k; continue
    }
    run = fencerun(s)
    if (run != "") {
      for (j = i + 1; j <= n && !closes(B[b, j], run); j++) ;
      push(tl, "code"); i = j + 1; continue
    }
    if (heading(s)) {
      push(tl, "heading")
      t = s; sub(/^ *#+/, "", t); sub(WSLEAD, "", t); sub(WSEND, "", t)
      if (t ~ /#$/) { s = t; sub(/#+$/, "", s); if (s == "" || s ~ / $/) { t = s; sub(WSLEAD, "", t); sub(WSEND, "", t) } }
      ak[tl] = "p"; add(tl, t); flush(tl)
      for (i++; i <= n && B[b, i] == ""; i++) ;
      continue
    }
    if (hr(s)) { push(tl, "hr"); for (i++; i <= n && B[b, i] == ""; i++) ; continue }
    if (s ~ /^ ? ? ?>/) {
      push(tl, "blockquote"); mark[tl] = no
      i += quote(b, i); continue
    }
    if (s ~ LIST) {
      push(tl, "list"); mark[tl] = no
      i += list(b, i)
      if (match(B[b, i - 1], WSEND)) { i--; B[b, i] = substr(B[b, i], RSTART) }
      continue
    }
    kind = htmlkind(b, i, i < n || !b)
    if (lost) break
    if (kind) { push(tl, "html"); i = html(b, i, kind); continue }
    k = def(b, i)
    if (lost) break
    if (k) {
      if (lastt[tl] == "paragraph" || lastt[tl] == "text") for (t = i; t < i + k; t++) add(tl, B[b, t])
      else push(tl, "def")
      i += k; continue
    }
    if (k = lheading(b, i)) {
      push(tl, "heading"); ak[tl] = "p"
      for (t = i; t < i + k - 1; t++) add(tl, B[b, t])
      flush(tl); i += k; continue
    }
    if (top) {
      for (j = i + 1; j <= n && !interrupts(B[b, j], j < n || !b); j++) ;
      if (!(clipped && lastt[tl] == "paragraph")) { push(tl, "paragraph"); ak[tl] = "p" }
      clipped = 0
      for (t = i; t < j; t++) add(tl, B[b, t])
      i = j
    } else {
      if (lastt[tl] != "text") { push(tl, "text"); ak[tl] = "t" }
      add(tl, s); i++
    }
  }
  # The lexer leaves this set after any list, so what follows a nested list in an item is a paragraph.
  top = 1; depth--
}

function take(line) {
  # A file that holds one of the three stand-in bytes is left unread.
  if (line ~ /[\001-\003]/) unsure = 1
  B[0, ++N[0]] = line
}
function feed(rec,   n, part, k) {
  sub(/\r$/, "", rec)
  if (!index(rec, "\r")) { take(rec); return }
  n = split(rec, part, "\r")
  for (k = 1; k <= n; k++) take(part[k])
}
function finish(   i, tl) {
  if (holder == "") return
  if (front == 1) for (i = 1; i <= held; i++) feed(hold[i])
  top = 1; lost = unsure; deep = 0; depth = 0; nb = 0; ntl = 0; no = 0
  tl = fresh(); blocks(0, tl, 0); flush(tl)
  if (deep) no = 0
  for (i = 1; i <= no; i++) if (!(out[i] in seen)) { seen[out[i]]; print holder "\t" out[i] }
  split("", B); split("", N); split("", seen); split("", lhfail); split("", A)
}
FNR == 1 { finish(); holder = FILENAME; front = 0; held = 0; unsure = 0; N[0] = 0 }
{
  rec = $0
  if (FNR == 1) {
    sub(/^\357\273\277/, "", rec)
    if (rec ~ FRONT) { front = 1; hold[++held] = rec; next }
    front = 3
  }
  # Frontmatter ends at the first three dashes anywhere, and the white space after them goes with it.
  if (front == 1) {
    if (!(at = index(rec, "---"))) { hold[++held] = rec; next }
    rec = substr(rec, at + 3); front = 2
  }
  if (front == 2) {
    sub(WSLEAD, "", rec)
    if (rec == "") next
    front = 3
  }
  feed(rec)
}
END { finish() }
'

import_tokens() { tr '\n' '\0' | LC_ALL=C xargs -0 awk "$IMPORT_AWK"; }

import_target() {
  case "$2" in
    "~/"*) REPLY="$HOME/${2#"~/"}";;
    /*) REPLY=$2;;
    *) REPLY="$1/$2";;
  esac
}
