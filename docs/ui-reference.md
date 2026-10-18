# UI and styling reference

Reference product: [Kofe Flow](https://www.kofeflow.com/), a native Mac menu bar Pomodoro timer. We borrow its principles, not its assets or exact look. The palette and tokens below are our own starting point; revise them after the first Mac prototype.

## Principles (taken from the reference)

1. **Time stays in sight.** The countdown lives in the menu bar and the iPhone Lock Screen. The app window is secondary.
2. **One click when rhythm changes.** Start, pause, extend, skip, reset are each one tap from the popover. No nested menus.
3. **Quiet by default.** Notifications are gentle. No badges, no streak guilt, no gamified noise.
4. **Time, not tasks.** A block has a free-text label. No task lists, due dates or priorities.
5. **Private insights.** Statistics are plain: focus hours, streaks, top labels.
6. **Platform-native feel.** System fonts, system materials, SF Symbols, standard controls. Each Shell follows its platform's conventions rather than matching pixel for pixel.

## Surfaces

### Mac

| Surface | Content |
| --- | --- |
| Menu bar item | Small phase glyph plus `mm:ss`. Idle shows only the glyph. Paused dims the digits. A break uses a different glyph tint. |
| Popover (about 280 pt wide) | Large `mm:ss`, phase name, label field, a progress ring, then controls: start or pause, extend (+5), skip, reset. Today's focus total sits in a footer. |
| Stats window | Today and week focus time, streak, a bar chart by day, a ranked list by label and Project. |
| Settings | Durations, long-break cadence, auto-start, sound, shortcuts, open at login, paired Devices, Agent tokens. |

### iPhone

| Surface | Content |
| --- | --- |
| Timer screen | A large progress ring with `mm:ss`, phase name, label field, a primary start or pause button, secondary extend and skip. |
| Live Activity | Lock Screen: ring, `mm:ss`, label, pause. Dynamic Island compact: glyph and time; expanded: the same as the Lock Screen. |
| Widgets | Small: time left or today's focus total. Medium: today plus a week mini-chart. |
| Stats tab | The same data as the Mac stats window in a vertical layout. |
| Settings | Matches the Mac, plus Pairing by QR code. |

## Design tokens

Tokens live in `spec/tokens.json` once created, so every Shell reads the same values. Starting set:

### Color

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `bg` | `#F6F3EC` | `#0F1A14` | Window and screen background |
| `surface` | `#FFFFFF` | `#16251C` | Cards, popover |
| `text` | `#16251C` | `#EDE9DD` | Primary text |
| `text-muted` | `#5E6B62` | `#98A59C` | Secondary text |
| `focus` | `#2F6B47` | `#5FB583` | Focus phase accent, ring |
| `break` | `#B7791F` | `#E0A94A` | Break phase accent |
| `danger` | `#B3412E` | `#E27763` | Reset and destructive actions |
| `hairline` | `#00000014` | `#FFFFFF1A` | Dividers |

The palette is a deep forest green with warm neutrals, in keeping with the reference's calm tone. Phase is conveyed by accent color plus the phase name and glyph, never color alone.

### Type

- System fonts only (SF Pro on Apple platforms).
- The countdown uses **monospaced digits** (`.monospacedDigit()`), so the width never jitters.
- Scale: countdown 56 pt (popover and iPhone), 17 pt body, 13 pt secondary, 11 pt caption.

### Shape, spacing, motion

- Spacing steps 4, 8, 12, 16, 24. Corner radius 12 for cards, 8 for controls.
- The progress ring is a 6 pt stroke with a round cap.
- Motion is minimal: a ring sweep and a short cross-fade between phases. Respect Reduce Motion.

### Icons

SF Symbols on Apple platforms. Phase glyphs: a filled circle for focus, a cup for break, and a pause bars glyph. The menu bar glyph is a template image so the system tints it.

## Behavior details that affect the design

- The ring and digits are derived from `ends_at - now`; they never depend on a network event.
- Paused shows the frozen remaining time with a "Paused" state.
- A block that ended while the Device was off shows its completed outcome on open, not a negative timer.
- Agent-started blocks show a small Source tag (for example "started by assistant") in the popover and the history.
- Pairing shows a QR code on the Mac and a scanner on the iPhone, with a confirmation code on both screens.

## Accessibility

- All controls have labels for VoiceOver. The countdown is announced on pause and at the end, not every second.
- Minimum 44 pt touch targets on iPhone.
- Contrast of text against `bg` and `surface` is at least 4.5:1 in both themes. Verify before finalizing the tokens.
- Dynamic Type is supported on iPhone.

## Not in the design

Task lists, account or login screens, upsell or Pro badges, social sharing cards, and onboarding carousels.
