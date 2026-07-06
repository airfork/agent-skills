# UI Drill Curriculum

The fixed teaching plan for `/ui-drill`. This file is never shown to the learner mid-exercise;
it governs sequencing. Modules run in order. Within a module, **core** terms gate completion
(each produced unprompted ~2 times, plus perception hit-rate ≥ ~80% over each flaw type's
last-5-exposure window); **extension** terms are taught and drilled but never gate.

Modules 1–5 are static visual critique. Modules 6–8 are interaction/UX critique and use
interactive mockups with a use-before-critique cue. Module 9 is the capstone.

---

## Module 1 — Visual hierarchy & Gestalt

The master concept plus the perceptual bedrock. Most "it feels bad" reactions are hierarchy
or grouping failures.

| Term | Tier | Gist |
|------|------|------|
| visual hierarchy | core | The order the eye is guided through content via size, weight, color, position |
| emphasis / focal point | core | The single element that should win attention on a surface |
| visual weight | core | How strongly an element attracts the eye (size, contrast, density) |
| proximity | core | Things near each other read as related; distance reads as unrelated |
| similarity | core | Things that look alike read as the same kind of thing |
| common region | core | A shared container (card, background) groups its contents |
| figure-ground | core | What reads as content vs backdrop; ambiguity here is disorienting |
| scanning pattern | extension | F/Z-pattern reading habits that layout should cooperate with |
| continuity | extension | Aligned elements read as a connected flow |
| dominance | extension | Deliberate inequality between elements to establish order |

Flaw patterns: `flat-hierarchy` (everything same size/weight, nothing leads),
`competing-emphasis` (two elements fight to be primary), `proximity-violation`
(related controls far apart, or unrelated items tightly grouped), `missing-grouping`
(no common region where one is needed), `buried-primary-action` (the key action has
less visual weight than secondary chrome).

## Module 2 — Spacing & layout

| Term | Tier | Gist |
|------|------|------|
| spacing scale | core | A consistent set of gap sizes (e.g. 4/8/16/24/32); ad-hoc gaps read as sloppy |
| whitespace / negative space | core | Empty space as an active grouping and breathing tool |
| vertical rhythm | core | Consistent vertical intervals that make a page feel composed |
| density | core | How much content per unit area; must match the task's intensity |
| grid alignment | core | Columns/edges that elements snap to; violations feel "off" |
| padding vs margin | core | Space inside a container vs between containers; confusing them breaks grouping |
| gutter | extension | The gap between columns/cards |
| optical spacing | extension | Adjusting mathematically-equal spacing so it *looks* equal |
| content width / measure of layout | extension | Constraining line and block width for comfort |

Flaw patterns: `inconsistent-spacing-scale` (three different gaps doing the same job),
`cramped-section` (insufficient breathing room), `uneven-padding` (asymmetric card/container
padding), `broken-grid` (one element off the shared columns), `whitespace-misgrouping`
(spacing implies the wrong relationships).

## Module 3 — Typography

| Term | Tier | Gist |
|------|------|------|
| type scale | core | A deliberate ramp of font sizes; arbitrary sizes read as noise |
| line-height (leading) | core | Vertical space within text blocks; cramped or floaty both hurt |
| line length (measure) | core | ~45–75 characters for body text; longer strains reading |
| weight contrast | core | Using font weight (not just size) to build hierarchy |
| typographic hierarchy | core | Headings/body/captions distinguishable at a glance |
| letter-spacing (tracking) | core | Especially needed for all-caps and small labels |
| text alignment | extension | Left-aligned body; centered text only for short display copy |
| font pairing | extension | Complementary typeface roles (display vs text) |
| widows / orphans | extension | Stranded single words/lines that break rhythm |

Flaw patterns: `no-type-scale` (near-identical sizes across levels), `cramped-leading`,
`overlong-measure`, `single-weight` (hierarchy attempted with size alone),
`centered-body-text`, `untracked-caps` (all-caps labels with default tracking).

## Module 4 — Color & contrast

| Term | Tier | Gist |
|------|------|------|
| contrast ratio | core | WCAG-measurable text/background contrast (AA: 4.5:1 body, 3:1 large) |
| semantic color | core | Colors carrying meaning (error red, success green) used consistently |
| accent restraint | core | One accent doing one job; many accents = no accent |
| neutral palette | core | The grayscale backbone most of the UI should be built from |
| color-only signaling | core | Meaning carried by hue alone excludes colorblind users; pair with icon/text |
| color hierarchy | core | Stronger color = more important; decoration shouldn't outshout content |
| saturation clash | extension | Adjacent high-saturation hues vibrating against each other |
| elevation | extension | Shadow/lightness conveying layer order |
| dark-mode parity | extension | Both themes maintaining hierarchy and contrast |

Flaw patterns: `low-contrast-text` (gray-on-gray), `color-only-state` (error indicated by
hue alone), `accent-overload` (several competing accents), `saturated-background`
(vivid fill behind body text), `semantic-mismatch` (destructive action in a friendly color).

## Module 5 — Alignment & consistency

| Term | Tier | Gist |
|------|------|------|
| edge alignment | core | Shared left/right edges; one stray element breaks the line |
| optical alignment | core | Aligning by visual mass, not bounding box (icons, quotes) |
| baseline alignment | core | Text and icons sitting on a shared baseline |
| component consistency | core | One visual treatment per component role (one primary-button style) |
| radius/border consistency | core | Uniform corner radii and stroke weights |
| iconography consistency | core | One icon style (stroke weight, fill, size grid) |
| optical centering | extension | Nudging glyphs/icons so they *look* centered |
| symmetry of spacing | extension | Matching spacing on equivalent sides |

Flaw patterns: `stray-edge` (one misaligned element), `mixed-radii`, `inconsistent-buttons`
(same action class, two treatments), `off-baseline-icon`, `mixed-icon-styles`.

## Module 6 — Affordances & signifiers (interactive)

| Term | Tier | Gist |
|------|------|------|
| affordance | core | What an element actually lets you do |
| signifier | core | The visible cue communicating the affordance (Norman's key distinction) |
| discoverability | core | Whether users can find that an action exists at all |
| mental model | core | What the user believes the system is; the UI should teach the right one |
| mapping | core | Control-to-effect relationships that match spatial/logical expectation |
| platform convention | core | Meeting learned expectations (links look like links) |
| perceived vs actual affordance | extension | Looks clickable but isn't, or is but doesn't look it |
| constraint | extension | Designs that make wrong actions impossible rather than warned-against |

Flaw patterns: `disguised-link` (interactive text styled as plain text),
`false-affordance` (non-interactive element styled clickable), `unmarked-clickable-card`,
`ambiguous-toggle-state` (can't tell on from off), `undiscoverable-action` (key action
hidden behind unlabeled icon or hover-only reveal).

## Module 7 — Feedback & system status (interactive)

| Term | Tier | Gist |
|------|------|------|
| visibility of system status | core | The system always shows what it's doing (Nielsen #1) |
| feedback | core | Immediate visible response to every user action |
| loading state | core | Explicit in-progress indication; silence reads as broken |
| disabled state | core | Visibly disabled *and* explaining why / how to enable |
| hover state | core | Pointer feedback confirming interactivity |
| focus state | core | Visible keyboard focus; removing outlines breaks a11y |
| progress indication | extension | Determinate progress for long operations |
| optimistic UI | extension | Reflecting an action instantly, reconciling in background |
| skeleton screen | extension | Structure-shaped placeholders over spinners |

Flaw patterns: `silent-submit` (no loading/response after click), `unexplained-disabled`,
`missing-hover`, `stripped-focus` (outline removed with no replacement), `silent-success`
(action completes with no confirmation), `frozen-progress` (indeterminate spinner where
progress is knowable).

## Module 8 — Flows, errors & edge states (interactive)

| Term | Tier | Gist |
|------|------|------|
| error prevention | core | Designing so the error can't happen (Nielsen #5) |
| error recovery | core | Errors say what happened, why, and how to fix it, without data loss |
| inline validation | core | Field-level checks at the right moment, not only on submit |
| empty state | core | First-run/no-data screens that orient and offer the next action |
| destructive confirmation | core | Guarding irreversible actions (or better: undo) |
| recognition over recall | core | Showing options instead of demanding memory (Nielsen #6) |
| friction | core | Steps/effort in a flow; deliberate for danger, minimal elsewhere |
| undo over confirm | extension | Reversibility beats interrogation |
| dead end | extension | A state with no path forward |
| blame-free error copy | extension | Errors that don't scold the user |

Flaw patterns: `submit-only-validation` (all errors dumped at the end, vaguely),
`vague-error` ("Something went wrong"), `missing-empty-state`, `unguarded-destructive`,
`data-losing-error` (form clears on failure), `dead-end-state`, `recall-demand`
(making the user remember codes/names the UI knows).

## Module 9 — Capstone

No new terms. Realistic compound-flaw screens mixing 4–6 flaws across all prior modules.
The learner writes a paragraph-length critique. Grading: standard per-flaw two-axis rubric
underneath (results feed the ledger), plus holistic assessment of prioritization
(worst first), severity calibration, and coherence. Module completes after two consecutive
capstones with ≥80% of planted flaws caught, a majority articulated `precise`, and a
holistic pass. Afterwards: maintenance mode.
