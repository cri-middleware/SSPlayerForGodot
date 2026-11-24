# 📦 Exporting Your Project

Once your scene plays correctly in the editor, you export it like any other Godot project (**Project → Export…**). SpriteStudio Player for Godot runs in exported builds for the platforms listed under [Limitations & Scope → Platforms & Export](../limitations.md#platforms--export). There are only a few plugin-specific points to know.

> [!NOTE]
> **A `.ssab` carries its images, audio and Instance targets as dependencies**, so the dependency-based export modes such as "Export selected scenes (and dependencies)" ship them too. What can still leave them out is an exclude filter; see [Generated Assets and Packs](generated_assets.md#choosing-an-export-mode).

## General

- **GDExtension variant** — the native library lives in your project's `addons/spritestudio/bin/`, and Godot bundles it into the export automatically. Desktop targets need nothing extra.
- **Custom module variant** — the plugin is compiled into the engine, so there is nothing plugin-specific to configure at export time.
- **Mobile / universal targets** — if an export stops with a message about the *ETC2/ASTC texture format being disabled*, enable **Project → Project Settings → Rendering → Textures → VRAM Compression → Import ETC2 ASTC**, then re-export.

## Web

With the **GDExtension** variant, a Web build needs **Extensions Support**: in the Export dialog, select your **Web** preset → **Options** → turn on **Extensions Support**. GDExtension libraries load on the Web only into an engine template built for dynamic linking, and this option selects that template. Godot's official export templates include it, so there is nothing else to install.

> [!WARNING]
> If a Web build fails at startup with *"GDExtension libraries are not supported by this engine version…"*, **Extensions Support** was off in the preset it was exported with.

Additional notes for the Web:

- The plugin runs **single-threaded (`nothread`)** on the Web, so leave **Thread Support** off in the preset. A plain HTTP server is enough to test the export — no special cross-origin (COOP/COEP) headers are required.
- A working GDExtension Web export produces an `index.side.wasm` next to `index.wasm`; its presence confirms the template for dynamic linking was used.
- The runtime uses **WebAssembly SIMD**, so the target browser must support it.

> [!NOTE]
> The **custom module** variant does not need *Extensions Support*, because the plugin is compiled into the engine. It still runs single-threaded on the Web, and (like every custom-module target) it uses **your own engine-built Web template**, which already contains the plugin, rather than a stock Godot template. That build/install flow is described in the [Build Guide](../development/build.md).
