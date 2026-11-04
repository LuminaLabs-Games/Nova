# Iris (LuminaLabs)

[SirMallard/iris](https://github.com/SirMallard/Iris), the immediate-mode debug UI library, with the
fixes every LuminaLabs game had been carrying in its own vendored copy. Use it in place of
`sirmallard/iris`; the API is unchanged.

```toml
# wally.toml
[dependencies]
Iris = "luminalabsgames/iris@2.5.3"
```

## What's in it

The base is upstream `main` at `1043909` (2026-10-19), which is the 2.5.1 release plus these fixes
from after it:

- A widget whose type changes under the same ID is now rebuilt instead of reused (#124).
- A Table that has been removed no longer errors in its per-frame border update (#129).
- `Iris.Init`'s `allowMultipleInits` argument is typed as optional (#127).

On top of that, four LuminaLabs patches, each marked with a comment in the source:

- **Mouse offset** (`widgets/init.lua`). Upstream reads the topbar inset once, when Iris loads. If
  that happens during client startup before the topbar has settled, the inset reads as (0, 0) and
  every mouse position comes in about 58px too low for the rest of the session. Combos close
  whenever a click or wheel scroll lands outside their rectangles, so items near the bottom of a
  dropdown could not be picked, and scrolling the list closed it. The patch keeps listening for
  topbar changes and reads the inset fresh on each `getMouseLocation`.
- **Late tabs** (`widgets/Tab.lua`). A Tab added to a TabBar after its first frame showed its
  contents even while another tab was selected, because nothing changed the index state to hide it.
  It now takes its visibility from the current index when it is added.
- **Scrolling tab bar** (`widgets/Tab.lua`). The tab strip is a horizontal ScrollingFrame, so a
  crowded TabBar scrolls sideways instead of overflowing the window.
- **New widget order** (`Internal.lua`, `_GenNewWidget`). Upstream works out a new widget's
  position among its siblings but only writes it to the Instance's `ZIndex` and `LayoutOrder` when
  an existing widget moves, so every new widget started at `LayoutOrder` 0. The parent's
  UIListLayout then fell back to creation order, and a row that first appeared among older siblings
  (a conditional row, a filtered list) drew at the bottom. New widgets now get both on creation,
  before they are parented, so Window's MenuBar override still applies. Window and Tooltip are
  skipped, as `_Insert` skips them.

`Internal._version` reads `2.5.3`, so the demo window shows which build is running.

## Updating from upstream

The files keep upstream's names (`.lua`) and layout so they diff cleanly against
`SirMallard/Iris/lib`. To take a new upstream release, copy its `lib/` over `src/`, put the four
patches back (search for `Patched (luminalabsgames/iris): upstream uses a one-shot TopbarInset`,
`Tabs added after the TabBar's first frame`, `horizontally-scrolling frame` and `Patched
(luminalabsgames/iris): upstream sets thisWidget.ZIndex` in this version), check whether upstream
fixed any of them itself, then bump `version` here and `Internal._version`. Publish with `wally publish` from this
folder.

Already fixed upstream, so no longer patched here: the Combo dropdown spilling off the bottom of the
screen (2.4 measures it with the list's `AbsoluteContentSize` and flips or scrolls it), and
`Iris.ComboEnum`'s default state (`enumType:GetEnumItems()[1]`). SlayABaddie's copy, based on
2.3.1, still patches both by hand.

## License

MIT, from upstream. See [LICENSE](LICENSE).
