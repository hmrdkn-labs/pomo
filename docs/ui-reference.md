# UI and styling reference: "Paper and ink"

Replaces the earlier green, ring-based direction (a copy of Kofe Flow's colour; dropped). Behaviour principles from Kofe Flow still hold; the look is ours.

## Principles

1. **Time stays in sight.** The countdown is in the menu bar and on the iPhone Lock Screen. The app window is secondary.
2. **One tap when rhythm changes.** Start, pause, extend, skip, reset, stop: each one tap from the main surface.
3. **Quiet by default.** No badges, no streak guilt, no confetti. One loud colour, used only for the running focus.
4. **Time, not tasks.** A block has a free-text label. No task lists.
5. **Typographic, not dashboard.** The numbers are the interface. A serif countdown, a thin rule, plain words. No ring, no cards inside cards.
6. **Platform-native behaviour.** System controls, system materials, SF Symbols, standard tab bar and settings. The look is ours, the interaction is Apple's.

## Concept

A paper notebook with one red pen. Warm off-white paper, near-black ink, and a single vermilion accent that appears only while a focus block runs (the rule, the glyph, the primary button). Breaks are slate blue, calm and cool. Everything else is ink on paper.

## Tokens (source of truth: `spec/tokens.json`)

### Colour

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `paper` | `#F5F0E6` | `#14110F` | Window and screen background |
| `paper-raised` | `#FFFDF8` | `#1E1A17` | Popover body, sheets, text fields |
| `ink` | `#1B1613` | `#F3EDE2` | Primary text, ink buttons |
| `ink-muted` | `#6F655B` | `#A39789` | Secondary text, idle rule track |
| `focus` | `#D63A22` | `#FF6A4D` | Focus phase: rule, glyph, Start button |
| `break` | `#4D5B6B` | `#8FA3B8` | Break phase: rule, glyph |
| `danger` | `#A12A1B` | `#E5806C` | Confirm-destructive text only |
| `hairline` | `#1B161320` | `#F3EDE226` | Dividers, field underlines |

Rules: text on `paper` or `paper-raised` is always `ink` or `ink-muted` (both pass 4.5:1). `focus` is never body text; as a fill it carries white (light) or `#14110F` (dark) text. Phase is never colour alone: the phase name and glyph always show.

### Type

| Role | Face | Size | Notes |
| --- | --- | --- | --- |
| `countdown` | system serif (New York), `.monospacedDigit()`, light weight | 84 popover, 104 iPhone, 40 Live Activity | Left-aligned; tabular so it never jitters |
| `phase` | system sans, semibold, small caps, tracking +1.2 | 12 | "FOCUS", "SHORT BREAK", "PAUSED" |
| `body` | system sans | 17 | Labels, buttons |
| `secondary` | system sans | 13 | Footers, sync line |
| `numeral` | system serif italic | 15 | Today's total, stat figures |

### Shape and spacing

- Spacing steps 4, 8, 12, 16, 24, 40. Screen margins 24 (iPhone), 20 (popover).
- Corner radius: 10 for controls and fields, 14 for popover and sheets. No pill buttons.
- The progress **rule** is 3 pt tall (4 pt on iPhone), square ends, full width. It starts full and shortens from the right as time passes; the idle track is `hairline`. No ring anywhere.

### Motion

- The rule length animates continuously with the clock (no easing jumps). Phase change is a 200 ms cross-fade of colour and glyph. Reduce Motion: the rule updates once per second and the cross-fade becomes an instant swap.

### Icons

SF Symbols. Phase glyph: filled circle (focus, `focus` colour), open circle (idle, `ink`), pause bars (paused, `ink-muted`), cup (break, `break`). Menu bar: running and break glyphs are coloured, idle is a template image.

## Surfaces

### Mac popover (width 300, padding 20)

Top to bottom:
1. Phase line (`phase` style) with the Source tag at the right when an agent started the block (small `ink-muted` text "by claude").
2. Countdown, 84 pt serif, left-aligned.
3. The rule, 3 pt, 12 pt below the digits.
4. Label field: no box, 1 pt `hairline` underline, placeholder "What are you working on?".
5. Primary button, full width, 44 pt tall, radius 10: idle shows "Start focus · 25 min" in `focus` fill; running shows "Pause" in `ink` fill (paper text); paused shows "Resume" in `ink` fill. The idle kind picker is a text segmented control above it (Focus / Short / Long).
6. Secondary row: four text-and-symbol buttons, no fills: `+5`, `Skip`, `Reset`, `Stop`, each `ink`; Reset and Stop use `ink-muted`. Stop asks no confirmation.
7. Footer: hairline, then "Today" with the total in `numeral` style, and icon buttons for Stats, Settings, Quit at the right.

### Mac menu bar item

Glyph plus `mm:ss` in the menu bar's system font, monospaced digits. Idle: glyph only. Paused: digits dimmed.

### iPhone Timer screen

Large title style top-left "Pomo" is not shown; instead the phase line sits at the top margin. Countdown 104 pt serif left-aligned at about one third of the screen height, the 4 pt rule under it, then the label field, then the primary button (52 pt), then the secondary row as four equal text buttons. Footer line with today's total and the sync status in `secondary`. Standard system tab bar (Timer, Stats, Devices, Settings), tinted `ink`, selected item `focus` only while a focus block runs, otherwise `ink`.

### Stats (both platforms)

Three figures in a row (Today, Week, Streak) as `numeral` over `secondary` captions, no card backgrounds. Bars per day drawn in `ink` (today in `focus`), baseline `hairline`. Ranked labels as a plain list with the time right-aligned in `numeral`.

### Settings and Devices

System grouped form on `paper`, rows on `paper-raised`. The pairing QR is always black on white with a 4-module quiet zone, inside a `paper-raised` panel.

### Live Activity and widgets (iPhone)

Lock Screen: `ink` (dark) background in both appearances, countdown in the serif at 40 pt in paper colour, a 3 pt `focus` rule, label in `ink-muted`. Dynamic Island compact: glyph and `mm:ss`; expanded: the Lock Screen layout. Home widget: today's focus total in `numeral` on `paper`, a vermilion dot when a block is running.

## Accessibility

- All controls labelled for VoiceOver. The countdown is announced on pause, resume and end, not every second.
- 44 pt minimum touch targets on iPhone.
- Contrast: `ink` on `paper` and on `paper-raised`, `ink-muted` on both, white on light `focus`, and `#14110F` on dark `focus` all at least 4.5:1 (verify programmatically in a test).
- Dynamic Type on iPhone: the countdown scales between 80 and 120 pt; the rest follows text styles.
- Reduce Motion, Increase Contrast (hairlines become `ink-muted`), and both appearances supported.

## Not in the design

Rings, gradients, shadows beyond the system popover shadow, cards within cards, task lists, account screens, upsell badges, onboarding carousels.
