#!/usr/bin/env pwsh
#
# Build the GitHub Pages site locally -- everything .github/workflows/pages.yml
# publishes, in the same order: the documentation in both locales into site/,
# then the playable Web demo into site/demo/.
# PowerShell twin of build-pages.sh.
#
#   scripts/build-pages.ps1                     # docs + demo from the latest release
#   scripts/build-pages.ps1 serve=yes           # ... and serve site/ on :8000
#   scripts/build-pages.ps1 tag=v7.0.0          # ... the demo from that release
#   scripts/build-pages.ps1 zip=<addon zip>     # ... from an addon zip on disk
#   scripts/build-pages.ps1 demo=no             # documentation only
#
# The demo is examples/Ringo exported for the Web with a released addon -- the
# ssplayer-godot-extension-<api>.zip a Release carries, the same file a user
# downloads -- and Godot's official Web template for GDExtension (Extensions
# Support on, threads off). pages.yml runs build-pages.sh from the tag a Release
# was published from, so the demo is that release. zip= takes an addon zip that
# is not in a Release yet: the release-dist artifact of a release.yml run, or
# what build-release.ps1 writes.
#
# The demo also needs, beside the addon:
#   - the .ssab, which deploy-examples.ps1 converts from the SpriteStudio-SDK
#     submodule's test projects (so a Rust toolchain);
#   - the Godot editor pinned in GODOT_VERSION.txt, which fetch-godot.ps1
#     installs into godot-bin\ when it is not there;
#   - that release's Web template, which fetch-godot-template.py takes out of the
#     official export templates without downloading the rest of them.
#
# Ordering: the English documentation build clears site/, and both the Japanese
# site (site/ja) and the demo (site/demo) live inside it -- so the demo goes in
# last, exactly as in pages.yml. Rerunning is safe; nothing here is incremental
# (the downloads are cached under scripts\.godot-cache\ and godot-bin\).
#
# What this does NOT reproduce is the deploy job (actions/deploy-pages) -- there
# is no local equivalent of publishing. Serving site/ over HTTP is as close as a
# local run gets, and it is enough to check every link, both locales and the
# demo actually running in a browser.
$ErrorActionPreference = "Stop"

$APP = Split-Path -Leaf $PSCommandPath
$ROOT_DIR = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# The sample project the demo is, and the official template it is exported with.
$DEMO_PROJECT = "examples/Ringo"
$WEB_TEMPLATE = "web_dlink_nothreads_release.zip"

# Windows PowerShell 5.1 has no $IsWindows, and runs only on Windows.
$onWindows = ($PSVersionTable.PSEdition -eq "Desktop") -or $IsWindows

function Fail {
    param([string] $Message, [int] $Code = 1)
    [Console]::Error.WriteLine("${APP}: $Message")
    exit $Code
}

# --- options --------------------------------------------------------------
$opts = [ordered]@{
    demo    = "yes"
    tag     = ""
    zip     = ""
    godot   = ""
    docs    = "yes"
    prepare = "auto"
    venv    = ".venv"
    serve   = "no"
    port    = "8000"
}

function Show-Usage {
    Write-Host "Usage: $APP [options]"
    Write-Host "$APP options:"
    Write-Host "  demo=<yes|no>           Export the Web demo into site/demo (default: yes)."
    Write-Host "                          no is the documentation alone."
    Write-Host "  tag=<vX.Y.Z>            Release whose addon zip the demo is exported with"
    Write-Host "                          (default: the latest)."
    Write-Host "  zip=<path>              Export with this addon zip instead of downloading one --"
    Write-Host "                          a release.yml run's release-dist, or build-release.ps1's."
    Write-Host "  godot=<path>            Godot editor to export with (default: godot-bin\, which"
    Write-Host "                          fetch-godot.ps1 fills when it is empty). It has to be the"
    Write-Host "                          version in scripts\GODOT_VERSION.txt, as the template is."
    Write-Host "  docs=<yes|no>           Build the documentation (default: yes). no keeps"
    Write-Host "                          whatever site/ already holds -- handy when only the"
    Write-Host "                          demo is being re-checked."
    Write-Host "  prepare=<auto|yes|no>   Run prepare-docs.ps1 first (default: auto)."
    Write-Host "                          auto = only when no zensical is found. yes forces it,"
    Write-Host "                          which is what a changed pin in docs/requirements.txt"
    Write-Host "                          needs; no is for CI, where it is a step of its own."
    Write-Host "  venv=<dir>              Virtualenv for the docs toolchain, relative to the"
    Write-Host "                          repo root (default: .venv). Passed to prepare-docs.ps1"
    Write-Host "                          and build-docs.ps1."
    Write-Host "  serve=<yes|no>          Serve site/ over HTTP when the build is done"
    Write-Host "                          (default: no). Foreground; Ctrl-C to stop."
    Write-Host "  port=<n>                Port for serve=yes (default: 8000)"
    Write-Host "  -h | --help             Show this help"
    Write-Host ""
    Write-Host "Output: site/ (en) + site/ja/ (ja) + site/demo/ -- the exact tree pages.yml"
    Write-Host "uploads. The documentation builds are --strict, so a broken internal link fails"
    Write-Host "the build here rather than on a release publish."
    Write-Host ""
    Write-Host "The demo needs, beside the addon: the SpriteStudio-SDK submodule and a Rust"
    Write-Host "toolchain (deploy-examples.ps1 converts its .ssab), Python, and gh unless zip="
    Write-Host "is given. The Godot editor and the Web template are downloaded."
    Write-Host ""
    Write-Host "Serve both locales from one server, or the language selector points at pages"
    Write-Host "that are not being served. The demo needs a server too: a browser does not"
    Write-Host "load WebAssembly from file://."
}

foreach ($item in $args) {
    if ($item -in "-h", "--help", "help") {
        Show-Usage
        exit 0
    } elseif ($item -match "=") {
        $key, $value = $item -split "=", 2
        if (-not $opts.Contains($key)) {
            Fail "unknown option '$key' (see $APP --help)" 2
        }
        # Lower-cased where the option is a keyword; tag=/zip=/godot=/venv=/port=
        # are not.
        $opts[$key] = if ($key -in "demo", "docs", "prepare", "serve") { $value.ToLower() } else { $value }
    } else {
        Fail "unknown argument '$item' (options are key=value; see $APP --help)" 2
    }
}

if ($opts.demo    -notin @("yes", "no"))         { Fail "demo must be yes or no (got '$($opts.demo)')" 2 }
if ($opts.docs    -notin @("yes", "no"))         { Fail "docs must be yes or no (got '$($opts.docs)')" 2 }
if ($opts.prepare -notin @("auto", "yes", "no")) { Fail "prepare must be auto, yes or no (got '$($opts.prepare)')" 2 }
if ($opts.serve   -notin @("yes", "no"))         { Fail "serve must be yes or no (got '$($opts.serve)')" 2 }
if ($opts.port -notmatch '^\d+$')                { Fail "port must be a number (got '$($opts.port)')" 2 }

# tag=/zip=/godot= describe the demo, so they are meaningless -- and, silently
# ignored, misleading -- without one.
if ($opts.demo -eq "no") {
    foreach ($given in @("tag", "zip", "godot")) {
        if ($opts[$given]) { Fail "$given= applies to demo=yes (got demo=no)" 2 }
    }
}
if ($opts.tag -and $opts.zip) {
    Fail "tag= and zip= are alternatives -- zip= is already a specific build" 2
}

$demoNote = ""
if ($opts.tag)   { $demoNote += " (tag $($opts.tag))" }
if ($opts.zip)   { $demoNote += " (zip $($opts.zip))" }
if ($opts.godot) { $demoNote += " (godot $($opts.godot))" }
$serveNote = if ($opts.serve -eq "no") { "" } else { " (port $($opts.port))" }

Write-Host "options"
Write-Host "  demo    => $($opts.demo)$demoNote"
Write-Host "  docs    => $($opts.docs)"
Write-Host "  prepare => $($opts.prepare)"
Write-Host "  venv    => $($opts.venv)"
Write-Host "  serve   => $($opts.serve)$serveNote"
Write-Host ""

# --- preflight ------------------------------------------------------------
if (-not (Test-Path (Join-Path $ROOT_DIR "mkdocs.base.yml"))) {
    Fail "mkdocs.base.yml not found -- is this the SSPlayerForGodot repo?"
}

# py first: it is the Windows launcher, and what build-docs.ps1 already tells
# people to serve with. python/python3 are the fallbacks elsewhere -- on Windows
# a bare `python` can be the Store stub that does nothing.
$PYTHON_CMD = $null
foreach ($candidate in @("py", "python", "python3")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $PYTHON_CMD = $candidate; break }
}

# The demo's tools are checked before the documentation build, so a run that
# cannot make the demo says so at once rather than after the docs.
if ($opts.demo -eq "yes") {
    $missing = @()
    if (-not $PYTHON_CMD) { $missing += "Python (py, python or python3)" }
    if (-not $opts.zip -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $missing += "gh (GitHub CLI), or zip=<addon zip>"
    }
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        $missing += "cargo (deploy-examples.ps1 builds ssconverter-cli)"
    }
    if (-not (Test-Path (Join-Path $ROOT_DIR "ss_player/SpriteStudio-SDK/cli/Cargo.toml"))) {
        $missing += "the SpriteStudio-SDK submodule (git submodule update --init ss_player/SpriteStudio-SDK)"
    }
    if ($opts.zip -and -not (Test-Path -LiteralPath $opts.zip -PathType Leaf)) { $missing += $opts.zip }
    if ($opts.godot -and -not (Test-Path -LiteralPath $opts.godot -PathType Leaf)) { $missing += "$($opts.godot) (godot=)" }
    if ($missing.Count -gt 0) {
        [Console]::Error.WriteLine("${APP}: the demo needs:")
        foreach ($m in $missing) { [Console]::Error.WriteLine("${APP}:   $m") }
        Fail "or build the documentation alone with demo=no"
    }
    # A relative zip=/godot= is the caller's, not the repo root's.
    if ($opts.zip)   { $opts.zip = (Resolve-Path -LiteralPath $opts.zip).Path }
    if ($opts.godot) { $opts.godot = (Resolve-Path -LiteralPath $opts.godot).Path }
}

$SITE_DIR = Join-Path $ROOT_DIR "site"
$DEMO_DIR = Join-Path $SITE_DIR "demo"

# Every script here resolves its own paths from the repo root, and site/ is
# written relative to it, so run from there however this was invoked.
Push-Location $ROOT_DIR
$tmp = $null
try {
    function Step {
        param([string] $What, [scriptblock] $Body)
        Write-Host ""
        Write-Host ">> $What"
        $global:LASTEXITCODE = 0
        & $Body
        if ($LASTEXITCODE -ne 0) { Fail "$What failed ($LASTEXITCODE)" $LASTEXITCODE }
    }

    # --- documentation ----------------------------------------------------
    # Same probe as build-docs.ps1: a venv laid out either way, else PATH (which
    # is how a run with no venv at all still works).
    function Test-Zensical {
        $venvDir = Join-Path $ROOT_DIR $opts.venv
        $venvBin = if (Test-Path (Join-Path $venvDir "Scripts")) {
            Join-Path $venvDir "Scripts"
        } else {
            Join-Path $venvDir "bin"
        }
        foreach ($candidate in @((Join-Path $venvBin "zensical.exe"), (Join-Path $venvBin "zensical"))) {
            if (Test-Path $candidate) { return $true }
        }
        return [bool](Get-Command zensical -ErrorAction SilentlyContinue)
    }

    if ($opts.docs -eq "yes") {
        $prepareScript = Join-Path $ROOT_DIR "scripts/prepare-docs.ps1"
        $buildScript = Join-Path $ROOT_DIR "scripts/build-docs.ps1"

        switch ($opts.prepare) {
            "yes" {
                Step "prepare-docs.ps1 venv=$($opts.venv)" { & $prepareScript "venv=$($opts.venv)" }
            }
            "auto" {
                if (Test-Zensical) {
                    Write-Host "${APP}: zensical already available; skipping prepare-docs.ps1 (prepare=yes forces it)"
                } else {
                    Step "prepare-docs.ps1 venv=$($opts.venv)" { & $prepareScript "venv=$($opts.venv)" }
                }
            }
            "no" { }
        }

        # Both locales, English first -- build-docs.ps1 owns that order, because the
        # English build clears site/ and the Japanese site lives inside it at site/ja.
        Step "build-docs.ps1 venv=$($opts.venv)" { & $buildScript "venv=$($opts.venv)" }
    } else {
        Write-Host "${APP}: docs=no -- site/ keeps whatever the last build left there"
    }

    # Puts a fixed "Powered by" box, linking to the docs (English and Japanese) and
    # the repository, into every *.html directly in $Dir, ahead of the last </body>.
    function Add-DemoLinks {
        param([string] $Dir, [string] $Root)
        if (!(Test-Path -LiteralPath $Dir -PathType Container)) { return }
        $a = 'target="_blank" rel="noopener" style="color:#fff"'
        # The Japanese link text is character references: Windows PowerShell 5.1 reads a
        # script with no BOM as ANSI.
        $links = '<div id="ss-demo-links" style="position:fixed;left:12px;bottom:12px;z-index:2147483647;padding:4px 10px;border-radius:6px;background:rgba(0,0,0,.65);color:#fff;font:12px/1.6 system-ui,sans-serif">' +
            "Powered by SpriteStudio Player for Godot &middot; <a href=`"$Root`" $a>Docs</a>" +
            " &middot; <a href=`"${Root}ja/`" lang=`"ja`" $a>&#12489;&#12461;&#12517;&#12513;&#12531;&#12488;</a>" +
            " &middot; <a href=`"https://github.com/cri-middleware/SSPlayerForGodot`" $a>GitHub</a></div>"
        foreach ($page in Get-ChildItem -LiteralPath $Dir -Filter '*.html' -File) {
            $text = [IO.File]::ReadAllText($page.FullName)
            if ($text.Contains('id="ss-demo-links"')) { continue }
            $at = $text.LastIndexOf('</body>', [StringComparison]::OrdinalIgnoreCase)
            if ($at -ge 0) {
                $text = $text.Insert($at, $links)
            } else {
                if ($text.Length -gt 0 -and !$text.EndsWith("`n")) { $text += "`n" }
                $text += $links
            }
            if (!$text.EndsWith("`n")) { $text += "`n" }
            [IO.File]::WriteAllText($page.FullName, $text)
        }
        Write-Host "   links to the docs and the repository -> site\$($Dir.Substring($SITE_DIR.Length).TrimStart('/', '\'))\*.html"
    }

    # Godot's exit status alone does not say an import or export worked, so an
    # ERROR line fails the step as well, the way run-tests.ps1's import pass does.
    function Invoke-Godot {
        param([string] $GodotBin, [string[]] $GodotArgs)
        Write-Host ""
        Write-Host ">> godot $($GodotArgs -join ' ')"
        # Windows PowerShell 5.1 turns a native command's redirected stderr into
        # error records, which Stop would end the script on.
        $ErrorActionPreference = "Continue"
        $log = & $GodotBin @GodotArgs 2>&1 | ForEach-Object { "$_" }
        $status = $LASTEXITCODE
        if ($status -ne 0 -or ($log | Select-String -Pattern '^ERROR:')) {
            [Console]::Error.WriteLine("${APP}: Godot failed (exit $status); the end of its output:")
            $log | Select-Object -Last 25 | ForEach-Object { [Console]::Error.WriteLine($_) }
            exit 1
        }
    }

    function Expand-Quietly {
        param([string] $Zip, [string] $Destination)
        # Expand-Archive is a script-module function: run from a session, it reads
        # the global progress preference rather than this script's.
        $savedProgress = $global:ProgressPreference
        $global:ProgressPreference = "SilentlyContinue"
        try {
            Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
        } finally {
            $global:ProgressPreference = $savedProgress
        }
    }

    # --- demo -------------------------------------------------------------
    if ($opts.demo -eq "yes") {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null

        # The addon: the asset release.yml attaches, named by the Godot API it targets.
        $global:LASTEXITCODE = 0
        $api = & (Join-Path $ROOT_DIR "scripts/godot-api-version.ps1")
        if ($LASTEXITCODE -ne 0 -or -not $api) { Fail "godot-api-version.ps1 failed ($LASTEXITCODE)" }
        $asset = "ssplayer-godot-extension-$api.zip"
        $src = $opts.zip
        if (-not $src) {
            Write-Host ""
            $from = if ($opts.tag) { $opts.tag } else { "(latest)" }
            Write-Host ">> gh release download $from --pattern $asset"
            $ghArgs = @("release", "download")
            if ($opts.tag) { $ghArgs += $opts.tag }
            $ghArgs += @("--pattern", $asset, "--dir", $tmp)
            $global:LASTEXITCODE = 0
            & gh @ghArgs
            if ($LASTEXITCODE -ne 0) {
                $from = if ($opts.tag) { $opts.tag } else { "the latest release" }
                [Console]::Error.WriteLine("")
                [Console]::Error.WriteLine("${APP}: could not download $asset from $from.")
                [Console]::Error.WriteLine("${APP}: A Release carries the addon zip for the Godot API it was built")
                [Console]::Error.WriteLine("${APP}: against, and this checkout targets $api. zip=<path> exports with an")
                Fail "addon zip on disk instead."
            }
            $src = Join-Path $tmp $asset
        }

        # The .ssab the sample loads. Converted every run: a stale conversion is the
        # first thing to rule out when an animation looks wrong.
        Step "deploy-examples.ps1" { & (Join-Path $ROOT_DIR "scripts/deploy-examples.ps1") }

        # The pinned editor, unless godot= names one. fetch-godot.ps1 does nothing
        # when the pin is already installed. It installs the Windows editor, so
        # elsewhere build-pages.sh (or godot=) is the way.
        $godotBin = $opts.godot
        if (-not $godotBin) {
            if ($onWindows) {
                Step "fetch-godot.ps1" { & (Join-Path $ROOT_DIR "scripts/fetch-godot.ps1") }
            }
            # The console wrapper first: PowerShell neither waits for nor captures
            # the GUI editor, which would leave Invoke-Godot no output to read.
            foreach ($cand in @(
                    (Join-Path $ROOT_DIR "godot-bin/godot_console.exe"),
                    (Join-Path $ROOT_DIR "godot-bin/godot"),
                    (Join-Path $ROOT_DIR "godot-bin/Godot.app/Contents/MacOS/Godot"))) {
                if (Test-Path $cand) { $godotBin = $cand; break }
            }
            if (-not $godotBin) { Fail "no Godot editor in godot-bin/ -- install it with scripts/fetch-godot.sh, or pass godot=<path>" }
        }

        Write-Host ""
        Write-Host ">> fetch-godot-template.py $WEB_TEMPLATE"
        $global:LASTEXITCODE = 0
        $template = & $PYTHON_CMD (Join-Path $ROOT_DIR "scripts/fetch-godot-template.py") $WEB_TEMPLATE | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0 -or -not $template) { Fail "fetch-godot-template.py failed ($LASTEXITCODE)" }

        # The project is exported from a copy, so nothing is written into the
        # sample: the addon, the editor's .godot/ and the export preset all land in
        # the copy.
        $stage = Join-Path $tmp "project"
        Write-Host ""
        Write-Host ">> staging $DEMO_PROJECT with the addon from $(Split-Path -Leaf $src)"
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Copy-Item -Path (Join-Path (Join-Path $ROOT_DIR $DEMO_PROJECT) "*") -Destination $stage -Recurse -Force
        # Left over from opening the sample in the editor, or from build-extension.ps1.
        # The sources config names the .sspj by a path relative to the sample, which
        # the copy does not have, and the demo plays the .ssab as they are.
        foreach ($leftover in @(".godot", "addons", ".ssplayer_sources.cfg")) {
            $p = Join-Path $stage $leftover
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Expand-Quietly $src $stage
        if (-not (Test-Path (Join-Path $stage "addons/spritestudio/spritestudio.gdextension"))) {
            Fail "$(Split-Path -Leaf $src) has no addons/spritestudio/spritestudio.gdextension"
        }

        $utf8 = New-Object System.Text.UTF8Encoding $false
        # The sample draws at its window's size from the top-left corner. A page
        # fills the browser instead, so the copy scales that view to the page, which
        # keeps the character in sight on a phone too.
        [IO.File]::AppendAllText((Join-Path $stage "project.godot"),
            "`n[display]`n`nwindow/stretch/mode=`"canvas_items`"`nwindow/stretch/aspect=`"keep`"`n", $utf8)

        # Named before Godot starts, for the reason run-tests.ps1's import pass
        # gives: an editor run that discovers an extension mid-scan crashes on the
        # way out.
        New-Item -ItemType Directory -Force -Path (Join-Path $stage ".godot") | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage ".godot/extension_list.cfg"),
            "res://addons/spritestudio/spritestudio.gdextension`n", $utf8)

        # Extensions Support picks the official template built for GDExtension; the
        # player's Web build is single-threaded. include_filter and exclude_filter
        # are written out because Godot prints an ERROR for each one a preset lacks.
        # The template path takes forward slashes: a backslash in a .cfg string is
        # an escape.
        $templatePath = $template.Replace('\', '/')
        $preset = @(
            '[preset.0]'
            ''
            'name="Web"'
            'platform="Web"'
            'runnable=true'
            'export_filter="all_resources"'
            'include_filter=""'
            'exclude_filter=""'
            'export_path=""'
            ''
            '[preset.0.options]'
            ''
            "custom_template/release=`"$templatePath`""
            'variant/extensions_support=true'
            'variant/thread_support=false'
            'vram_texture_compression/for_desktop=true'
            'vram_texture_compression/for_mobile=false'
            'html/canvas_resize_policy=2'
            'html/focus_canvas_on_start=true'
        ) -join "`n"
        [IO.File]::WriteAllText((Join-Path $stage "export_presets.cfg"), "$preset`n", $utf8)

        Invoke-Godot $godotBin @("--headless", "--path", $stage, "--import")
        if (Test-Path $DEMO_DIR) { Remove-Item -Recurse -Force $DEMO_DIR }
        New-Item -ItemType Directory -Force -Path $DEMO_DIR | Out-Null
        $exportPath = (Join-Path $DEMO_DIR "index.html").Replace('\', '/')
        Invoke-Godot $godotBin @("--headless", "--path", $stage, "--export-release", "Web", $exportPath)

        # index.side.wasm is there only when the export took the template built for
        # GDExtension, and the extension's own wasm only when Godot took the addon.
        foreach ($f in @("index.html", "index.pck", "index.wasm", "index.side.wasm",
                         "libSSGodot.web.template_release.wasm32.nothreads.wasm")) {
            if (-not (Test-Path (Join-Path $DEMO_DIR $f))) { Fail "the export left no site/demo/$f" }
        }
        Add-DemoLinks $DEMO_DIR "../"
    } else {
        Write-Host ""
        Write-Host "${APP}: demo=no -- site/demo is not part of this build"
    }
} finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    Pop-Location
}

# --- what landed ----------------------------------------------------------
Write-Host ""
Write-Host "${APP}: done -> site/"
function Report {
    param([string] $Path, [string] $Label)
    if (Test-Path (Join-Path $ROOT_DIR $Path)) {
        Write-Host "  ${Label}: $Path"
    } else {
        Write-Host "  ${Label}: MISSING ($Path)"
    }
}
Report "site/index.html" "en  "
Report "site/ja/index.html" "ja  "
if ($opts.demo -eq "yes") { Report "site/demo/index.html" "demo" }

# --- serve ----------------------------------------------------------------
# Bound to loopback, in the command it suggests as well. On every interface,
# http.server announces http://[::]:PORT/, which is not a secure context, so
# Copy as Markdown cannot copy there.
Write-Host ""
if ($opts.serve -eq "yes") {
    if (-not $PYTHON_CMD) {
        Fail "no python on PATH to serve with -- use any static server on site/"
    }
    Write-Host "${APP}: http://localhost:$($opts.port)/  (English)"
    Write-Host "${APP}: http://localhost:$($opts.port)/ja/  (Japanese)"
    if ($opts.demo -eq "yes") { Write-Host "${APP}: http://localhost:$($opts.port)/demo/  (Web demo)" }
    Write-Host "${APP}: Ctrl-C to stop"
    Write-Host ""
    Push-Location $ROOT_DIR
    try {
        & $PYTHON_CMD -m http.server $opts.port --bind 127.0.0.1 -d site
    } finally {
        Pop-Location
    }
    exit $LASTEXITCODE
} else {
    $shown = if ($PYTHON_CMD) { $PYTHON_CMD } else { "python" }
    Write-Host "${APP}: serve it (one server over both locales, so the language selector resolves):"
    Write-Host "${APP}:   $APP serve=yes"
    Write-Host "${APP}:   $shown -m http.server $($opts.port) --bind 127.0.0.1 -d site"
}
