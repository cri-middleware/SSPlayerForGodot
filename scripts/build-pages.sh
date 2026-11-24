#!/usr/bin/env bash
#
# Build the GitHub Pages site locally -- everything .github/workflows/pages.yml
# publishes, in the same order: the documentation in both locales into site/,
# then the playable Web demo into site/demo/.
#
#   scripts/build-pages.sh                     # docs + demo from the latest release
#   scripts/build-pages.sh serve=yes           # ... and serve site/ on :8000
#   scripts/build-pages.sh tag=v7.0.0          # ... the demo from that release
#   scripts/build-pages.sh zip=<addon zip>     # ... from an addon zip on disk
#   scripts/build-pages.sh demo=no             # documentation only
#
# The demo is examples/Ringo exported for the Web with a released addon -- the
# ssplayer-godot-extension-<api>.zip a Release carries, the same file a user
# downloads -- and Godot's official Web template for GDExtension (Extensions
# Support on, threads off). pages.yml runs this from the tag a Release was
# published from, so the demo is that release. zip= takes an addon zip that is
# not in a Release yet: the release-dist artifact of a release.yml run, or what
# build-release.sh writes.
#
# The demo also needs, beside the addon:
#   - the .ssab, which deploy-examples.sh converts from the SpriteStudio-SDK
#     submodule's test projects (so a Rust toolchain);
#   - the Godot editor pinned in GODOT_VERSION.txt, which fetch-godot.sh installs
#     into godot-bin/ when it is not there;
#   - that release's Web template, which fetch-godot-template.py takes out of the
#     official export templates without downloading the rest of them.
#
# Ordering: the English documentation build clears site/, and both the Japanese
# site (site/ja) and the demo (site/demo) live inside it -- so the demo goes in
# last, exactly as in pages.yml. Rerunning is safe; nothing here is incremental
# (the downloads are cached under scripts/.godot-cache/ and godot-bin/).
#
# What this does NOT reproduce is the deploy job (actions/deploy-pages) -- there
# is no local equivalent of publishing. Serving site/ over HTTP is as close as a
# local run gets, and it is enough to check every link, both locales and the
# demo actually running in a browser.
set -euo pipefail

APP="$(basename "$0")"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The sample project the demo is, and the official template it is exported with.
DEMO_PROJECT="examples/Ringo"
WEB_TEMPLATE="web_dlink_nothreads_release.zip"

# --- options --------------------------------------------------------------
DEMO="yes"
TAG=""
ZIP=""
GODOT=""
DOCS="yes"
PREPARE="auto"
VENV=".venv"
SERVE="no"
PORT="8000"

usage () {
  echo "Usage: $APP [options]"
  echo "$APP options:"
  echo "  demo=<yes|no>           Export the Web demo into site/demo (default: $DEMO)."
  echo "                          no is the documentation alone."
  echo "  tag=<vX.Y.Z>            Release whose addon zip the demo is exported with"
  echo "                          (default: the latest)."
  echo "  zip=<path>              Export with this addon zip instead of downloading one --"
  echo "                          a release.yml run's release-dist, or build-release.sh's."
  echo "  godot=<path>            Godot editor to export with (default: godot-bin/, which"
  echo "                          fetch-godot.sh fills when it is empty). It has to be the"
  echo "                          version in scripts/GODOT_VERSION.txt, as the template is."
  echo "  docs=<yes|no>           Build the documentation (default: $DOCS). no keeps"
  echo "                          whatever site/ already holds -- handy when only the"
  echo "                          demo is being re-checked."
  echo "  prepare=<auto|yes|no>   Run prepare-docs.sh first (default: $PREPARE)."
  echo "                          auto = only when no zensical is found. yes forces it,"
  echo "                          which is what a changed pin in docs/requirements.txt"
  echo "                          needs; no is for CI, where it is a step of its own."
  echo "  venv=<dir>              Virtualenv for the docs toolchain, relative to the"
  echo "                          repo root (default: $VENV). Passed to prepare-docs.sh"
  echo "                          and build-docs.sh."
  echo "  serve=<yes|no>          Serve site/ over HTTP when the build is done"
  echo "                          (default: $SERVE). Foreground; Ctrl-C to stop."
  echo "  port=<n>                Port for serve=yes (default: $PORT)"
  echo "  -h | --help             Show this help"
  echo ""
  echo "Output: site/ (en) + site/ja/ (ja) + site/demo/ -- the exact tree pages.yml"
  echo "uploads. The documentation builds are --strict, so a broken internal link fails"
  echo "the build here rather than on a release publish."
  echo ""
  echo "The demo needs, beside the addon: the SpriteStudio-SDK submodule and a Rust"
  echo "toolchain (deploy-examples.sh converts its .ssab), python3, unzip, and gh"
  echo "unless zip= is given. The Godot editor and the Web template are downloaded."
  echo ""
  echo "Serve both locales from one server, or the language selector points at pages"
  echo "that are not being served. The demo needs a server too: a browser does not"
  echo "load WebAssembly from file://."
}

while [ $# -gt 0 ]; do
  item="$1"
  shift

  case "$item" in
    -h|--help|help)
      usage
      exit 0
      ;;
    *=*)
      key="${item%%=*}"
      value="${item#*=}"
      case "$key" in
        # Lower-cased where the option is a keyword; tag=/zip=/godot=/venv=/port=
        # are not.
        demo)    DEMO="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        tag)     TAG="$value" ;;
        zip)     ZIP="$value" ;;
        godot)   GODOT="$value" ;;
        docs)    DOCS="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        prepare) PREPARE="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        venv)    VENV="$value" ;;
        serve)   SERVE="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ;;
        port)    PORT="$value" ;;
        *)
          echo "$APP: unknown option '$key' (see $APP --help)" >&2
          exit 2
          ;;
      esac
      ;;
    *)
      echo "$APP: unknown argument '$item' (options are key=value; see $APP --help)" >&2
      exit 2
      ;;
  esac
done

case "$DEMO" in yes|no) ;; *) echo "$APP: demo must be yes or no (got '$DEMO')" >&2; exit 2 ;; esac
case "$DOCS" in yes|no) ;; *) echo "$APP: docs must be yes or no (got '$DOCS')" >&2; exit 2 ;; esac
case "$PREPARE" in auto|yes|no) ;; *) echo "$APP: prepare must be auto, yes or no (got '$PREPARE')" >&2; exit 2 ;; esac
case "$SERVE" in yes|no) ;; *) echo "$APP: serve must be yes or no (got '$SERVE')" >&2; exit 2 ;; esac
case "$PORT" in ''|*[!0-9]*) echo "$APP: port must be a number (got '$PORT')" >&2; exit 2 ;; esac

# tag=/zip=/godot= describe the demo, so they are meaningless -- and, silently
# ignored, misleading -- without one.
if [ "$DEMO" = "no" ]; then
  for given in ${TAG:+tag} ${ZIP:+zip} ${GODOT:+godot}; do
    echo "$APP: $given= applies to demo=yes (got demo=no)" >&2
    exit 2
  done
fi
if [ -n "$TAG" ] && [ -n "$ZIP" ]; then
  echo "$APP: tag= and zip= are alternatives -- zip= is already a specific build" >&2
  exit 2
fi

SERVE_NOTE=""
[ "$SERVE" = "no" ] || SERVE_NOTE=" (port $PORT)"

echo "options"
echo "  demo    => $DEMO${TAG:+ (tag $TAG)}${ZIP:+ (zip $ZIP)}${GODOT:+ (godot $GODOT)}"
echo "  docs    => $DOCS"
echo "  prepare => $PREPARE"
echo "  venv    => $VENV"
echo "  serve   => $SERVE$SERVE_NOTE"
echo ""

# --- preflight ------------------------------------------------------------
if [ ! -f "$ROOT_DIR/mkdocs.base.yml" ]; then
  echo "$APP: mkdocs.base.yml not found -- is this the SSPlayerForGodot repo?" >&2
  exit 1
fi

PYTHON_CMD="python3"
command -v "$PYTHON_CMD" > /dev/null 2>&1 || PYTHON_CMD="python"

# The demo's tools are checked before the documentation build, so a run that
# cannot make the demo says so at once rather than after the docs.
if [ "$DEMO" = "yes" ]; then
  missing=()
  command -v unzip > /dev/null 2>&1 || missing+=("unzip")
  command -v "$PYTHON_CMD" > /dev/null 2>&1 || missing+=("python3")
  [ -n "$ZIP" ] || command -v gh > /dev/null 2>&1 || missing+=("gh (GitHub CLI), or zip=<addon zip>")
  command -v cargo > /dev/null 2>&1 || missing+=("cargo (deploy-examples.sh builds ssconverter-cli)")
  [ -f "$ROOT_DIR/ss_player/SpriteStudio-SDK/cli/Cargo.toml" ] \
    || missing+=("the SpriteStudio-SDK submodule (git submodule update --init ss_player/SpriteStudio-SDK)")
  if [ -n "$ZIP" ] && [ ! -f "$ZIP" ]; then
    missing+=("$ZIP")
  fi
  if [ -n "$GODOT" ] && [ ! -x "$GODOT" ]; then
    missing+=("$GODOT (godot=)")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "$APP: the demo needs:" >&2
    printf '%s\n' "${missing[@]}" | sed "s/^/$APP:   /" >&2
    echo "$APP: or build the documentation alone with demo=no" >&2
    exit 1
  fi
  # A relative zip= is the caller's, not the repo root's.
  if [ -n "$ZIP" ]; then ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"; fi
  if [ -n "$GODOT" ]; then GODOT="$(cd "$(dirname "$GODOT")" && pwd)/$(basename "$GODOT")"; fi
fi

# Every script here resolves its own paths from the repo root, and site/ is
# written relative to it, so run from there however this was invoked.
cd "$ROOT_DIR"

SITE_DIR="$ROOT_DIR/site"
DEMO_DIR="$SITE_DIR/demo"

TMP_DIR=""
cleanup () {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

step () {
  echo ""
  echo ">> $*"
  "$@"
}

# --- documentation --------------------------------------------------------
# Same probe as build-docs.sh: a venv laid out either way, else PATH (which is
# how a run with no venv at all still works).
have_zensical () {
  local venv_bin="$ROOT_DIR/$VENV/bin"
  [ -d "$ROOT_DIR/$VENV/Scripts" ] && venv_bin="$ROOT_DIR/$VENV/Scripts"
  [ -x "$venv_bin/zensical" ] || [ -x "$venv_bin/zensical.exe" ] \
    || command -v zensical > /dev/null 2>&1
}

if [ "$DOCS" = "yes" ]; then
  case "$PREPARE" in
    yes)
      step ./scripts/prepare-docs.sh venv="$VENV"
      ;;
    auto)
      if have_zensical; then
        echo "$APP: zensical already available; skipping prepare-docs.sh (prepare=yes forces it)"
      else
        step ./scripts/prepare-docs.sh venv="$VENV"
      fi
      ;;
    no) ;;
  esac

  # Both locales, English first -- build-docs.sh owns that order, because the
  # English build clears site/ and the Japanese site lives inside it at site/ja.
  step ./scripts/build-docs.sh venv="$VENV"
else
  echo "$APP: docs=no -- site/ keeps whatever the last build left there"
fi

# add_demo_links <dir> <path from its pages to the site root>
# Puts a fixed "Powered by" box, linking to the docs (English and Japanese) and
# the repository, into every *.html directly in <dir>, ahead of the last </body>.
add_demo_links () {
  local dir="$1" root="$2" page
  [ -d "$dir" ] || return 0
  local a='target="_blank" rel="noopener" style="color:#fff"'
  local links='<div id="ss-demo-links" style="position:fixed;left:12px;bottom:12px;z-index:2147483647;padding:4px 10px;border-radius:6px;background:rgba(0,0,0,.65);color:#fff;font:12px/1.6 system-ui,sans-serif">'
  links+="Powered by SpriteStudio Player for Godot &middot; <a href=\"$root\" $a>Docs</a>"
  # "ドキュメント" as character references, the same bytes the .ps1 twin writes.
  links+=" &middot; <a href=\"${root}ja/\" lang=\"ja\" $a>&#12489;&#12461;&#12517;&#12513;&#12531;&#12488;</a>"
  links+=" &middot; <a href=\"https://github.com/cri-middleware/SSPlayerForGodot\" $a>GitHub</a></div>"
  for page in "$dir"/*.html; do
    [ -f "$page" ] || continue
    grep -q 'id="ss-demo-links"' "$page" && continue
    awk -v links="$links" '
      { line[NR] = $0 }
      END {
        for (at = NR; at > 0; at--) if (tolower(line[at]) ~ /<\/body>/) break
        for (i = 1; i <= NR; i++) {
          if (i != at) { print line[i]; continue }
          lc = tolower(line[i]); j = 0
          while ((k = index(substr(lc, j + 1), "</body>")) > 0) j += k
          print substr(line[i], 1, j - 1) links substr(line[i], j)
        }
        if (at == 0) print links
      }' "$page" > "$page.tmp"
    mv "$page.tmp" "$page"
  done
  echo "   links to the docs and the repository -> site/${dir#"$SITE_DIR"/}/*.html"
}

# run_godot <log name> <godot args...>
# Godot's exit status alone does not say an import or export worked, so an
# ERROR line fails the step as well, the way run-tests.sh's import pass does.
run_godot () {
  local log="$TMP_DIR/$1.log" status
  shift
  echo ""
  echo ">> godot $*"
  set +e
  "$GODOT_BIN" "$@" > "$log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ] || grep -q '^ERROR:' "$log"; then
    echo "$APP: Godot failed (exit $status); the end of its output:" >&2
    tail -n 25 "$log" >&2
    exit 1
  fi
}

# --- demo -----------------------------------------------------------------
build_demo () {
  TMP_DIR="$(mktemp -d)"

  # The addon: the asset release.yml attaches, named by the Godot API it targets.
  local api asset src
  api="$(./scripts/godot-api-version.sh)"
  asset="ssplayer-godot-extension-${api}.zip"
  src="$ZIP"
  if [ -z "$src" ]; then
    echo ""
    echo ">> gh release download ${TAG:-(latest)} --pattern $asset"
    gh release download ${TAG:+"$TAG"} --pattern "$asset" --dir "$TMP_DIR" || {
      echo "" >&2
      echo "$APP: could not download $asset from ${TAG:-the latest release}." >&2
      echo "$APP: A Release carries the addon zip for the Godot API it was built" >&2
      echo "$APP: against, and this checkout targets $api. zip=<path> exports with an" >&2
      echo "$APP: addon zip on disk instead." >&2
      exit 1
    }
    src="$TMP_DIR/$asset"
  fi

  # The .ssab the sample loads. Converted every run: a stale conversion is the
  # first thing to rule out when an animation looks wrong.
  step ./scripts/deploy-examples.sh

  # The pinned editor, unless godot= names one. fetch-godot.sh does nothing when
  # the pin is already installed.
  GODOT_BIN="$GODOT"
  if [ -z "$GODOT_BIN" ]; then
    step ./scripts/fetch-godot.sh
    local cand
    for cand in \
        "$ROOT_DIR/godot-bin/Godot.app/Contents/MacOS/Godot" \
        "$ROOT_DIR/godot-bin/godot"; do
      if [ -x "$cand" ]; then GODOT_BIN="$cand"; break; fi
    done
    [ -n "$GODOT_BIN" ] || { echo "$APP: fetch-godot.sh left no editor in godot-bin/" >&2; exit 1; }
  fi

  local template
  echo ""
  echo ">> fetch-godot-template.py $WEB_TEMPLATE"
  template="$("$PYTHON_CMD" scripts/fetch-godot-template.py "$WEB_TEMPLATE" | tail -n 1)"

  # The project is exported from a copy, so nothing is written into the sample:
  # the addon, the editor's .godot/ and the export preset all land in the copy.
  local stage="$TMP_DIR/project"
  echo ""
  echo ">> staging $DEMO_PROJECT with the addon from $(basename "$src")"
  mkdir -p "$stage"
  cp -R "$ROOT_DIR/$DEMO_PROJECT/." "$stage/"
  # Left over from opening the sample in the editor, or from build-extension.sh.
  # The sources config names the .sspj by a path relative to the sample, which
  # the copy does not have, and the demo plays the .ssab as they are.
  rm -rf "$stage/.godot" "$stage/addons" "$stage/.ssplayer_sources.cfg"
  unzip -q "$src" 'addons/*' -d "$stage"
  [ -f "$stage/addons/spritestudio/spritestudio.gdextension" ] \
    || { echo "$APP: $(basename "$src") has no addons/spritestudio/spritestudio.gdextension" >&2; exit 1; }

  # The sample draws at its window's size from the top-left corner. A page fills
  # the browser instead, so the copy scales that view to the page, which keeps the
  # character in sight on a phone too.
  printf '\n[display]\n\nwindow/stretch/mode="canvas_items"\nwindow/stretch/aspect="keep"\n' >> "$stage/project.godot"

  # Named before Godot starts, for the reason run-tests.sh's import pass gives:
  # an editor run that discovers an extension mid-scan crashes on the way out.
  mkdir -p "$stage/.godot"
  echo "res://addons/spritestudio/spritestudio.gdextension" > "$stage/.godot/extension_list.cfg"

  # Extensions Support picks the official template built for GDExtension; the
  # player's Web build is single-threaded. include_filter and exclude_filter are
  # written out because Godot prints an ERROR for each one a preset lacks.
  cat > "$stage/export_presets.cfg" <<EOF
[preset.0]

name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""

[preset.0.options]

custom_template/release="$template"
variant/extensions_support=true
variant/thread_support=false
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=false
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
EOF

  run_godot import --headless --path "$stage" --import
  rm -rf "$DEMO_DIR"
  mkdir -p "$DEMO_DIR"
  run_godot export --headless --path "$stage" --export-release "Web" "$DEMO_DIR/index.html"

  # index.side.wasm is there only when the export took the template built for
  # GDExtension, and the extension's own wasm only when Godot took the addon.
  local f
  for f in index.html index.pck index.wasm index.side.wasm \
           "libSSGodot.web.template_release.wasm32.nothreads.wasm"; do
    [ -f "$DEMO_DIR/$f" ] || { echo "$APP: the export left no site/demo/$f" >&2; exit 1; }
  done
  add_demo_links "$DEMO_DIR" "../"

  # Here rather than in the EXIT trap alone: serve=yes execs the server, and the
  # trap never runs.
  rm -rf "$TMP_DIR"
  TMP_DIR=""
}

if [ "$DEMO" = "yes" ]; then
  build_demo
else
  echo ""
  echo "$APP: demo=no -- site/demo is not part of this build"
fi

# --- what landed ----------------------------------------------------------
echo ""
echo "$APP: done -> site/"
report () { # <path> <label>
  if [ -e "$ROOT_DIR/$1" ]; then
    echo "  $2: $1"
  else
    echo "  $2: MISSING ($1)"
  fi
}
report "site/index.html" "en  "
report "site/ja/index.html" "ja  "
if [ "$DEMO" = "yes" ]; then
  report "site/demo/index.html" "demo"
fi

# --- serve ----------------------------------------------------------------
# Bound to loopback, in the command it suggests as well. On every interface,
# http.server announces http://[::]:PORT/, which is not a secure context, so
# Copy as Markdown cannot copy there.
echo ""
if [ "$SERVE" = "yes" ]; then
  command -v "$PYTHON_CMD" > /dev/null 2>&1 || {
    echo "$APP: no python on PATH to serve with -- use any static server on site/" >&2
    exit 1
  }
  echo "$APP: http://localhost:$PORT/  (English)"
  echo "$APP: http://localhost:$PORT/ja/  (Japanese)"
  if [ "$DEMO" = "yes" ]; then
    echo "$APP: http://localhost:$PORT/demo/  (Web demo)"
  fi
  echo "$APP: Ctrl-C to stop"
  echo ""
  exec "$PYTHON_CMD" -m http.server "$PORT" --bind 127.0.0.1 -d site
else
  echo "$APP: serve it (one server over both locales, so the language selector resolves):"
  echo "$APP:   $APP serve=yes"
  echo "$APP:   $PYTHON_CMD -m http.server $PORT --bind 127.0.0.1 -d site"
fi
