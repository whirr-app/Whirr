# ADR 0010: Tab root titles stay on the system default

- Status: Accepted
- Date: 2026-09-15

Supersedes the `root-header-relocation` plan (`RHA.*`), which is deleted. This record keeps its two
reusable findings and the reasoning that closed it.

## Context

Each tab root — Home, Podcasts, Library, Search — carries a `navigationTitle` that repeats the word
on its own tab-bar item, and pays the standard large-title band for it: roughly 50 pt, measured on
an iOS 27 iPhone 17 simulator. The tab bar never scrolls away, so the band looked like duplicated
space, and the original complaint was that it was not earning it.

Three arrangements were built and shown to the owner on device. All three were rejected.

**Relocating the title onto the toolbar row** (`.toolbarTitleDisplayMode(.inlineLarge)`). At rest
this does what was wanted: the title renders large and leading-aligned beside the trailing controls
and the band goes. But `.inlineLarge` governs the resting state only — on scroll the system still
collapses the title to small and centred over its own backdrop. The result buys back 50 pt at rest
and spends it on a permanently denser scrolled bar carrying both the title and the controls, where
the default collapses to a light tinted word. Accepted on Library and Search, rejected on Home and
Podcasts.

**Pinning the title** with a leading `ToolbarItem`. This works (see the recipe below), but the
owner's reference is Apple Music's Home, where the header is *absent* once scrolled, not pinned.

**Scrolling the title away while the controls float.** This is the Spotify arrangement, not the
Apple one: in the reference captures Apple Music takes the whole bar away, avatar included. Keeping
a control floating over scrolled content means it can no longer be a toolbar item, because the bar
reserves its height whether or not anything is in it. `rootToolbarTrailingOrder` arbitrates an
ordered, conditional group of four controls across all four tabs plus two leading status
indicators; moving it into a content overlay would hand the app the scroll-edge interaction, the
morph between conditionally present items, overflow at large Dynamic Type, popover anchoring for
`BrowseFilterMenu`, safe-area participation and the navigation bar's accessibility grouping — all
of which the bar supplies for free. Rejected as not worth it.

Narrowing the first arrangement to the two roots where it was accepted was also tried, and made
things worse: four tabs you swipe between then carried two different title arrangements.

## Decision

All four tab roots keep `navigationTitle` with **no display mode set at all**, which is the
pre-existing behaviour and the platform default. `RootTitleChrome` is deleted.

The separate scroll-edge work stands: pushed titled screens claim `role: .titled` so their title
sits on the system's own backdrop rather than compositing over passing artwork, and tab roots keep
`.soft`.

## Consequences

- Every root looks the same as every other, and the same as an Apple app. The ~50 pt band is the
  standard cost of a large title and is accepted.
- Do not write an explicit `.navigationBarTitleDisplayMode(.automatic)` in place of writing
  nothing. Device-verified on iOS 27: that axis overrides `toolbarTitleDisplayMode` whenever it is
  applied, `.automatic` included, so an explicit `.automatic` is not the same as leaving it unset.
- **The edge role travels with the bar row's contents.** A hard top edge paints a backdrop and a
  separator behind the row, which earns its keep only when the row carries something. Moving a root
  title onto the row and then moving it back without its edge role following it left a filled,
  separated strip around a lone gear — worse than either arrangement it sat between. Pinned by
  `RootHeaderChromeTests`.
- **A root's edge role lives with its scroll host, which is not always its root view.** Home and
  Podcasts host their own scroll view, so reverting the root view reverted the role with it. Library
  and Search delegate theirs to `LibraryBrowseIndexView`, `LibraryBrowseGridViews`, `SearchIdleView`
  and `SearchResultsList`, so the first revert left those two roots hard-edged while the other two
  went soft — half a revert, and visible as a frosted strip on Library alone. The test scans the six
  scroll hosts, not the four root views.

## Findings worth not re-deriving

**A fixed, non-collapsing title is reachable.** An earlier draft recorded that the toolbar refuses
an oversized `Text` and overflows it into a `•••` button. That is a misreading: the bar allots a
leading item roughly one control's width, so the `Text` is *width-starved*, not refused — at
`.title2` the same item renders as `H…`. Four modifiers together do it: keep `navigationTitle` for
back-button labels and the VoiceOver rotor, `toolbar(removing: .title)` to stop the bar drawing it,
`.toolbarTitleDisplayMode(.inline)` to collapse the band (`toolbar(removing:)` alone does not), and
the leading `ToolbarItem` with `.fixedSize()`. The glass capsule was never the obstacle; `•••`
appears with and without `sharedBackgroundVisibility(.hidden)`.

**A `List` will not let its first row overlap the navigation bar.** This blocks any in-content
header on Podcasts, which keeps its `List` because its episode rows carry `.swipeActions` and those
exist only inside one. Four mechanisms were tried on device and all failed: negative
`listRowInsets` clamps (~21 pt of 54 delivered), negative `safeAreaPadding` is ignored entirely,
negative `contentMargins(_:for: .scrollContent)` scrolls the row out of reach, and `.offset(y:)`
draws the row up but leaves its height behind as a hole. Matching Home there means changing
Podcasts' outer container, which is an owner-gated structural change — start from that constraint,
not from the title modifiers.

**The bar's height is not exposed to the view inside it.** It measured 54 pt on iOS 27 (the nominal
inline bar is 44 pt) and does not scale with Dynamic Type, so any constant derived from it is a
measurement that will drift.
