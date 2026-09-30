#!/usr/bin/env python3
"""End-to-end tests for rg-fzf: runs the real script in a pseudo-terminal, sends
keypresses, and reads results back through fzf's --listen API.

Usage: python3 tests/test_rg_fzf.py     (needs rg, fzf, jq; bat optional)
"""
import fcntl, json, os, pty, re, select, signal, struct, subprocess, sys, tempfile, termios, time, urllib.request

signal.alarm(240)  # hard stop so the suite can never hang
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rg-fzf.sh")
PORT = 6350
ESC_RE = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")

LONG = "x" * 600 + " initLong end"
T = tempfile.mkdtemp()   # searched tree
H = tempfile.mkdtemp()   # harness files, outside the searched tree
os.makedirs(f"{T}/my dir")
FILES = {
    "my dir/a b.txt": b"hello World\nfoo\n",
    "other.py": b"HELLO there\nbar\n",
    "notes.md": b'hello "quoted" \\ back\ttab\n',
    "my dir/.secret": b"hello hidden\n",
    "-dash.txt": b"hello dash\n",
    "n:12:3:x.txt": b"line one\nhello colon: yes\n",
    "latin1.txt": b"caf\xe9 hello\n",
    "app.js": ("const initialLevel = data?.initialLevel || x;\n// Initial level\n" + LONG + "\n").encode(),
}
for p, c in FILES.items():
    open(f"{T}/{p}", "wb").write(c)
ALL_HELLO = ["-dash.txt", "latin1.txt", "my dir/a b.txt", "n:12:3:x.txt", "notes.md", "other.py"]
ALL_FILES = sorted(ALL_HELLO + ["app.js"])

run = f"{H}/run.sh"
open(run, "w").write(open(SCRIPT).read().replace("\nfzf \\\n", f"\nfzf --listen {PORT} \\\n", 1))
editor_log = f"{H}/editor.log"
editor = f"{H}/fake-editor"
open(editor, "w").write(f"#!/bin/bash\nprintf '%s\\n' \"$@\" > '{editor_log}'\n")
os.chmod(editor, 0o755)

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -> {str(detail)[:400]}"))
    fails += 0 if cond else 1

class Session:
    def __init__(self, *args):
        self.out = b""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(T)
            os.environ["EDITOR"] = editor
            os.execvp("bash", ["bash", run, *args])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
        self.pump(2)

    def pump(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.out += os.read(self.fd, 65536)
                except OSError:
                    return

    def key(self, b, wait=1.0):
        os.write(self.fd, b)
        self.pump(wait)

    def api(self):
        return json.load(urllib.request.urlopen(f"http://localhost:{PORT}?limit=200", timeout=5))

    def state(self):
        d = self.api()
        return d["query"], sorted(m["text"] for m in d["matches"])

    def screen(self):
        return ESC_RE.sub(b"", self.out)

    def finish(self, keys):
        """Press the exit keys; return the raw bytes printed after fzf leaves the screen."""
        self.key(keys, 2.5)
        self.pump(1)
        os.waitpid(self.pid, 0)
        tail = self.out[self.out.rfind(b"\x1b[?1049l"):]
        return ESC_RE.sub(b"", tail).replace(b"\r", b"").strip()

def load(raw, name):
    try:
        return json.loads(raw.decode())
    except ValueError:
        check(name + ": valid JSON", False, raw[:400])
        return None

CLR = b"\x7f" * 30  # backspaces; Ctrl-U is bound to preview scroll in rg-fzf
fields = lambda line: line.split("\x00:")
names = lambda m: sorted(fields(x)[0] for x in m)

def cli(*args):
    p = subprocess.run(["bash", SCRIPT, *args], cwd=T, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=5)
    return p.returncode, p.stdout + p.stderr

# ---------- Command-line arguments ----------
check("-h prints help", cli("-h") == (0, cli("--help")[1]) and "Usage:" in cli("-h")[1])
check("-t with no value is an error", cli("-t")[0] == 1 and "needs a file type" in cli("-t")[1])
check("unknown type is an error", cli("-t", "nosuch")[0] == 1)
check("'-t j.' is rejected (no regex matching)", cli("-t", "j.")[0] == 1)
check("unknown option is an error", cli("-x")[0] == 1 and "unknown option" in cli("-x")[1])
check("missing path is an error", cli("/nope")[0] == 1 and "no such file" in cli("/nope")[1])

# ---------- Session 1: interactive behaviour, plain Enter output ----------
s = Session()
q, m = s.state()
check("startup lists visible files, no hidden", names(m) == ALL_FILES, m)
check("header shows M-enter:json and M-p:pcre2", b"M-enter:json" in s.screen() and b"M-p:pcre2" in s.screen())
check("prompt shows Content (regex)>", b"Content (regex)>" in s.screen())

s.key(b"hello")
q, m = s.state()
check("content search, ignore-case", names(m) == ALL_HELLO and any("HELLO there" in x for x in m), m)
check("match highlighted", b"1;31mHELLO" in s.out)
check("colon filename displays normally", b"n:12:3:x.txt:2:1:hello colon: yes" in s.screen())

s.key(b"\x1bh")
q, m = s.state()
check("Alt-H adds hidden file", any(".secret" in x for x in m), m)
check("prompt shows [H]", b"Content (regex) [H]>" in s.screen())
s.key(b"\x1bh")
s.key(b"\x1bv")
q, m = s.state()
check("Alt-V shows only non-matching lines", "foo" in [fields(x)[-1] for x in m] and not any("hello" in x.lower() for x in m), m)
check("prompt shows [V]", b"Content (regex) [V]>" in s.screen())
s.key(b"\x1bv")

s.key(b"\x06")
q, m = s.state()
check("Ctrl-F: filename mode shows all matches", q == "" and len(m) == 6, (q, m))
check("prompt shows Filename (fuzzy)>", b"Filename (fuzzy)>" in s.screen())
s.key(b"n12")
check("filename 'n12' matches the colon filename only", names(s.state()[1]) == ["n:12:3:x.txt"])
s.key(CLR + b"ab")
check("filename 'ab' fuzzy-matches 'my dir/a b.txt'", names(s.state()[1]) == ["my dir/a b.txt"])
s.key(CLR + b"helloworld")
check("filename mode ignores line text", s.state()[1] == [])
s.key(CLR + b"txt$")
check("filename 'txt$' (anchor) keeps only .txt files", names(s.state()[1]) == ["-dash.txt", "latin1.txt", "my dir/a b.txt", "n:12:3:x.txt"])
s.key(CLR + b"!txt")
check("filename '!txt' (negation) excludes .txt files", names(s.state()[1]) == ["notes.md", "other.py"])
s.key(CLR + b"ab")
s.key(b"\x1bh")
q, m = s.state()
check("Alt-H in filename mode keeps the filter", q == "ab" and names(m) == ["my dir/a b.txt"], (q, m))
s.key(b"\x1bh")

before = len(s.out)
s.key(b"\x06", 1.5)
q, m = s.state()
check("Ctrl-F back: query restored and scoped", q == "hello" and names(m) == ["my dir/a b.txt"], (q, m))
check("highlight kept after switching back", re.search(rb"31[;0-9]*mhello", s.out[before:]) is not None)
s.key(CLR + b"foo")
q, m = s.state()
check("new word stays scoped", q == "foo" and len(m) == 1, (q, m))
s.key(CLR + b"hello")

s.key(b"\x06")
check("re-enter filename mode: text restored", s.state()[0] == "ab")
s.key(CLR + b"!txt"); s.key(b"\x06")
check("negated filename scope carries back to content mode", names(s.state()[1]) == ["notes.md", "other.py"])
s.key(b"\x06"); s.key(CLR + b"n12"); s.key(b"\x06")
s.key(b"\x05", 1.5)
log = open(editor_log).read().split("\n") if os.path.exists(editor_log) else []
check("Ctrl-E on colon filename opens right file and line", log[:2] == ["n:12:3:x.txt", "+2"], log)
s.key(b"\x06"); s.key(CLR + b"dash"); s.key(b"\x06")
s.key(b"\x05", 1.5)
check("Ctrl-E on '-dash.txt'", open(editor_log).read().split("\n")[:2] == ["-dash.txt", "+1"])
s.key(b"\x06"); s.key(CLR + b"zzz"); s.key(b"\x06")
check("filename text matching nothing gives no results", s.state()[1] == [])
s.key(b"\x06"); s.key(CLR + b""); s.key(b"\x06")
q, m = s.state()
check("scope cleared: all matches back", q == "hello" and len(m) == 6, (q, m))

s.key(CLR + b"(")
check("invalid regex gives no results (no crash)", s.state()[1] == [])
s.key(CLR + b"-e")
check("pattern starting with '-' is searched, not an option", s.state()[1] == [])
s.key(CLR + b"$(touch pwned)")
check("pattern is never run as a command", not os.path.exists(f"{T}/pwned"))
s.key(b"\x1bv"); s.key(b"\x1bv"); s.key(b"\x06"); s.key(b"\x06")
check("...also not by toggles or mode switches", not os.path.exists(f"{T}/pwned"))
s.key(CLR + b"(?<=const )\\w+")
check("lookbehind gives no results with the default engine", s.state()[1] == [])
s.key(b"\x1bp")
check("Alt-P: prompt shows Content (pcre2)", b"Content (pcre2)>" in s.screen())
check("Alt-P: lookbehind works", [fields(x)[-1] for x in s.state()[1]] == ["const initialLevel = data?.initialLevel || x;"])
s.key(CLR + b"\\b{start}hello")
check("Alt-P: PCRE2 really used (\\b{start} unsupported)", s.state()[1] == [])
s.key(CLR + b"hello")
check("Alt-P: normal search works", len(s.state()[1]) == 6)
s.key(b"\x06")
check("Alt-P in filename mode shows [P]", b"Filename (fuzzy) [P]>" in s.screen())
s.key(b"ab"); s.key(b"\x1bp")
q, m = s.state()
check("Alt-P off in filename mode keeps the filter", q == "ab" and names(m) == ["my dir/a b.txt"], (q, m))
last = s.screen().rfind(b"Filename (fuzzy)")
check("Alt-P off: [P] flag removed", s.screen()[last:last + 22].startswith(b"Filename (fuzzy)>"), s.screen()[last:last + 30])
s.key(CLR); s.key(b"\x06")
check("back to content (regex)", s.state()[0] == "hello" and len(s.state()[1]) == 6)
s.key(CLR + b"hello")

s.key(CLR + b"\\b{start}hello")
check("default engine: \\b{start} works", len(s.state()[1]) == 6)
s.key(CLR + b"hello")

for fname, want in [("-dash.txt", "hello dash"), ("n:12:3:x.txt", "hello colon")]:
    prev = subprocess.run(["bash", "-c", 'bat --color=never --highlight-line 1 -- "$1" 2>/dev/null || cat -- "$1"', "_", fname],
                          cwd=T, capture_output=True, text=True).stdout
    check(f"preview command works for '{fname}'", want in prev, prev)

s.key(b"\t\t")
check("Tab selects two rows", len(s.api()["selected"]) == 2)
s.key(b"\x1b[Z")
check("Shift-Tab toggles and moves back", len(s.api()["selected"]) == 3)
s.key(b"\x1b[Z"); s.key(b"\x1b[Z")
sel = sorted(x["text"] for x in s.api()["selected"])
check("Shift-Tab deselects", len(sel) == 1, sel)
raw = s.finish(b"\r")
want = [x.replace("\x00", "").encode() for x in sel]
check("Enter prints the selected line as file:line:column:text", raw.split(b"\n") == want, (raw, want))
check("plain output has no NUL", b"\x00" not in raw)

# ---------- Session 2: plain Enter keeps non-UTF-8 bytes ----------
s = Session()
s.key(b"hello"); s.key(b"\x06"); s.key(b"latin"); s.key(b"\x06"); s.key(b"\x01")
raw = s.finish(b"\r")
check("Enter output: invalid UTF-8 shown as U+FFFD, rest intact", raw == "latin1.txt:1:6:caf\ufffd hello".encode(), raw)

# ---------- Session 3: Alt-Enter JSON, plain word, special characters ----------
s = Session()
s.key(b"hello"); s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "matches JSON")
if d:
    check("JSON is {query, results}", set(d) == {"query", "results"} and d["query"] == "hello", list(d))
    r = {x["file"]: x for x in d["results"]}
    check("all 6 results", sorted(r) == ALL_HELLO, sorted(r))
    check("result keys file/line/column/text/matches", all(set(x) == {"file", "line", "column", "text", "matches"} for x in d["results"]))
    check("matches keep the file's case", r["other.py"]["matches"] == ["HELLO"], r["other.py"])
    c = r["n:12:3:x.txt"]
    check("colon filename exact", (c["line"], c["column"], c["text"], c["matches"]) == (2, 1, "hello colon: yes", ["hello"]), c)
    check("quotes, backslash, tab survive", r["notes.md"]["text"] == 'hello "quoted" \\ back\ttab', r["notes.md"])
    check("Latin-1 line still has its match", r["latin1.txt"]["matches"] == ["hello"] and r["latin1.txt"]["text"].endswith(" hello"), r["latin1.txt"])

# ---------- Session 4: regex with several matches per line, long line ----------
s = Session()
s.key(b"init\\w+", 1.5); s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "regex JSON")
if d:
    check("regex query recorded exactly", d["query"] == "init\\w+", d["query"])
    by_line = {x["line"]: x for x in d["results"]}
    check("two matches on one line", by_line.get(1, {}).get("matches") == ["initialLevel", "initialLevel"], by_line.get(1))
    check("case-insensitive match text", by_line.get(2, {}).get("matches") == ["Initial"], by_line.get(2))
    lng = by_line.get(3, {})
    check("line over 500 chars is complete in JSON", lng.get("text") == LONG and lng.get("matches") == ["initLong"], len(lng.get("text", "")))

# ---------- Session 4b: JSON re-search uses PCRE2 while Alt-P is on ----------
s = Session()
s.key(b"\x1bp"); s.key(b"(?<=const )\\w+", 1.5); s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "PCRE2 JSON")
if d:
    check("JSON with Alt-P: lookbehind matches", [x["matches"] for x in d["results"]] == [["initialLevel"]], d)

# ---------- Session 5: Alt-Enter from filename mode uses the content query ----------
s = Session()
s.key(b"hello"); s.key(b"\x06"); s.key(b"ab"); s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "filename-mode JSON")
if d:
    check("filename mode: query is the search, not filename text", d["query"] == "hello", d["query"])
    check("filename mode: only scoped file, with matches",
          [(x["file"], x["matches"]) for x in d["results"]] == [("my dir/a b.txt", ["hello"])], d["results"])

# ---------- Session 6: invert mode ----------
s = Session()
s.key(b"hello"); s.key(b"\x1bv"); s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "invert JSON")
if d:
    check("invert: file/line/text only, no column or matches",
          d["results"] and all(set(x) == {"file", "line", "text"} for x in d["results"]) and d["query"] == "hello", d)

# ---------- Session 7: empty-search file list ----------
s = Session()
s.key(b"\x01")
d = load(s.finish(b"\x1b\r"), "file-list JSON")
if d:
    check("file list: query '' and {file} entries",
          d["query"] == "" and sorted(x["file"] for x in d["results"]) == ALL_FILES and all(set(x) == {"file"} for x in d["results"]), d)

# ---------- Session 8: -t and path arguments ----------
s = Session("-t", "py")
s.key(b"hello")
check("-t py searches only .py files", names(s.state()[1]) == ["other.py"])
s.finish(b"\x1b")
s = Session("my dir")
s.key(b"hello")
check("path with spaces as argument", names(s.state()[1]) == ["my dir/a b.txt"])
s.finish(b"\x1b")
s = Session("notes.md")
s.key(b"hello")
check("single file argument shows its filename", names(s.state()[1]) == ["notes.md"])

# ---------- Session 9: Esc prints nothing ----------
check("Esc prints nothing", s.finish(b"\x1b") == b"")

tmp = os.environ.get("TMPDIR", "/tmp")
leftover = [x for x in os.listdir(tmp) if os.path.isfile(os.path.join(tmp, x, "search.sh"))]
check("state dirs removed on exit", not leftover, leftover)

subprocess.run(["rm", "-rf", T, H])
print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
