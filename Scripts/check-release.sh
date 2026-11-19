#!/bin/bash
# Release gate (test plan 0.9 + 0.10): no debug hooks in Release binaries, and clean user-facing text.
#   Scripts/check-release.sh            build iOS + Mac Release, check both, then lint copy
#   Scripts/check-release.sh copy       copy lint only (seconds)
# Exit code 1 when anything is found. Build logs go to build/release-*.log.
cd "$(dirname "$0")/.."
fail=0

# Strings that exist only inside #if DEBUG. One in a Release binary means a test hook shipped.
hooks='-UITest|-QA[A-Z]|-autoScrollTest|QAHooks|DebugHooks|UITestDemo'

check_binary() { # $1 = label, $2 = binary path
  if [ ! -f "$2" ]; then echo "✗ $1: no binary at $2"; fail=1; return; fi
  found=$(strings -a "$2" | grep -E -- "$hooks" | sort -u | head -10)
  if [ -n "$found" ]; then echo "✗ $1 Release has debug hooks:"; echo "$found" | sed 's/^/    /'; fail=1
  else echo "☑ $1 Release: no debug hooks"; fi
}

if [ "${1:-}" != copy ]; then
  p=build/DerivedData/Build/Products
  # A failed build leaves the old binary behind, so only a fresh build is checked.
  if Scripts/build.sh ios Release > build/release-ios.log 2>&1; then check_binary iOS "$p/Release-iphonesimulator/Lelvo.app/Lelvo"
  else echo "✗ iOS Release build failed (build/release-ios.log)"; fail=1; fi
  if Scripts/build.sh mac Release > build/release-mac.log 2>&1; then
    app=$(ls -td $p/Release/*.app 2>/dev/null | head -1)
    check_binary Mac "$app/Contents/MacOS/$(basename "$app" .app)"
  else echo "✗ Mac Release build failed (build/release-mac.log)"; fail=1; fi
  # Android: R8 keeps only reachable code; the debug screens live in src/debug, so check the release APK too when built.
  apk=$(ls -t android/app/build/outputs/apk/release/*.apk 2>/dev/null | head -1)
  if [ -n "$apk" ]; then
    if unzip -p "$apk" 'classes*.dex' | strings -a | grep -qE 'BackgroundLab|app/lelvo/android/debug'; then
      echo "✗ Android release APK has debug screens"; fail=1
    else echo "☑ Android release: no debug screens ($apk)"; fi
  else echo "– Android release APK not built; skip (cd android && ./gradlew assembleRelease)"; fi
fi

# Copy lint over user-facing text: Swift string literals in views/services, and Android strings.xml + Compose Text("...").
# Rules (AGENTS.md): no "!", no TODO/FIXME, no "beta", no old name "Memvo" (crypto labels like "Memvo-CGFE" are allowed).
python3 - <<'EOF' || fail=1
import pathlib, re, sys
roots = ["Shared", "iOS", "macOS", "android/app/src/main"]
lit = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# Only literals that read like a sentence a user sees: a capital letter, then a space or more words.
userish = re.compile(r"^[A-Z][a-z']+[ ,]")
rules = [
    ("exclamation mark", re.compile(r"[a-z)]!(\s|$)")),
    ("TODO/FIXME", re.compile(r"\b(TODO|FIXME)\b")),
    ("'beta'", re.compile(r"\bbeta\b", re.I)),
    ("old name Memvo", re.compile(r"\bMemvo\b(?!-?(CGFE|v\d|crypto|Key|Salt))")),
]
skip_dirs = ("/debug/", "Tests/", "UITests", "/QAHooks", "/DebugHooks", "/Preview")
hits = []
for root in roots:
    for f in pathlib.Path(root).rglob("*"):
        if f.suffix not in (".swift", ".kt", ".xml") or any(s in str(f) for s in skip_dirs):
            continue
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            s = line.strip()
            if s.startswith(("//", "///", "*", "AppLog", "appLog", "Log.", "print(", "assert", "precondition", "fatalError")):
                continue
            if "AppLog." in s or "appLog(" in s or "Logger" in s:
                continue
            texts = [m.group(1) for m in lit.finditer(line)]
            if f.suffix == ".xml":
                texts += re.findall(r">([^<]+)<", line)
            for t in texts:
                if f.suffix != ".xml" and not userish.match(t):
                    continue
                for name, rx in rules:
                    if rx.search(t):
                        hits.append(f"{f}:{n}: {name}: {t[:80]}")
if hits:
    print(f"✗ Copy lint: {len(hits)} finding(s)")
    for h in hits[:60]: print("    " + h)
    sys.exit(1)
print("☑ Copy lint: clean")
EOF

exit $fail
