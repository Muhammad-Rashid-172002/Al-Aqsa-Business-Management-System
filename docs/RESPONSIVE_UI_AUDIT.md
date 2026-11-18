# Responsive UI & Overflow Audit — 16 Nov 2026

Scope: every screen, dialog, popup, table and form of the AL AQSA CCTV desktop app (18 modules), at the sizes a shop laptop or desktop may use, including Windows display scaling.

**Status:** code fixed, static analysis clean, automated responsive tests written. These tests need the Flutter engine and **must be run on your Mac/PC**: see section 5. Their results are not in yet, and no viewport is claimed as tested until they are.

## 1. The three reported problems

| # | Where | Root cause | Fix |
|---|---|---|---|
| R1 | POS → Billing → **Payment method** dropdown | `DropdownButtonFormField` sizes itself to its **widest item** unless `isExpanded` is set. Flutter 3.41 lays it out as `Row(mainAxisSize: min)` holding an `IndexedStack` as wide as "JazzCash / Easypaisa". In the narrow half-width slot of the fixed 460 px bill panel, that Row overflowed. | New shared `AppDropdown` (`lib/ui/widgets/forms.dart`): `isExpanded: true`, the selected value is shown on one line with an ellipsis, and the open menu shows every option in full (menu width is capped at the window width, height ≤ 420 px). The bill panel width is now responsive (340–460 px). |
| R2 | Serial Numbers → **Status** | Same dropdown root cause in the fixed 240 px Status filter. Its longest label is "Repairable (Not Sellable)". Status badges (`StatusPill`) had no ellipsis, so they could spill out of narrow table cells and dialog headers. | Status filter uses `AppDropdown` with a flexible 200–260 px width. `StatusPill` is now single-line, ellipsized, with a tooltip showing the full text. The Status column has more room (flex 3, min 170 px), and the table scrolls sideways if the window is narrower than all columns. |
| R3 | **Notification** bell / panel | Each notification was a `PopupMenuItem` containing `Row(Icon, Text)` with a bare `Text`. Flutter popup menus are capped at **280 px**, so a sentence like "3 returned item(s) awaiting your inspection" overflowed. | Rebuilt panel: width 240–380 px, never wider than the window. It has a header with a count, rows that wrap (`Expanded` text), an "all caught up" empty state, and a badge that shows "9+" beyond 9. The top bar around it is responsive too (see A1). |

## 2. Other problems found by the full audit

| # | Screen | Problem & root cause | Fix |
|---|---|---|---|
| A0 | **Windows runner** (`windows/runner`) | The minimum window was a fixed **1200×720 physical px** and the app opened at 1440×900. On a 1024×600 screen, or a 1366×768 laptop at 125–150% scaling, the window was larger than the screen, so its bottom (POS "Complete") was off-screen. No Flutter-side fix can solve that. | The minimum is now 800×500 logical × DPI, clamped to the monitor work area. The app opens **maximized** when the default size doesn't fit. Type-checked against the Windows SDK and Flutter 3.41.6 headers. **The Windows build itself is not yet verified.** |
| A1 | Top bar | About 920 px of fixed-width children (360 px search, button, long date, account name) in about 730 px at 1024 wide. | Search is flexible (≤360 px) and becomes an icon below 720 px. "New Sale" becomes an icon button with a tooltip and the date gets shorter below 900 px. The account shows the avatar only (name is in its menu). |
| A2 | Sidebar | A fixed 248 px width ate a quarter of a 1024 px screen. Labels overflowed during the open/close animation (Row with `Expanded` at ~8 px wide). | Collapses automatically below 1180 px; the user's toggle still wins. Labels follow the *animated* width (`LayoutBuilder`), so no frame overflows. |
| A3 | All pages | Pages built from `Expanded` panels were squeezed to unusable heights on short windows (≈430 px of client area at 1366×768 @150%). | `MinSizeScroll` around every page: below 720×560 the page scrolls instead of squeezing. It does nothing on larger windows. |
| A4 | `PageHeader` (every page) | `Row(Expanded(title), Wrap(actions))`: the `Wrap` got unbounded width, so 3–4 action buttons overflowed. | Actions sit in a `Flexible` right-aligned `Wrap`, and stack under the title below 760 px. |
| A5 | `AppTable` (all lists) | Columns shrank without limit, and fixed cell content (pills, buttons) overflowed. | Each column has a minimum width; the table scrolls horizontally with a draggable scrollbar (Shift+wheel also works). The pager stays fixed and headers wrap to 2 lines. |
| A6 | `FormDialog` (≈40 dialogs) | The action row was a plain `Row`: up to 5 buttons (invoice / purchase / repair detail) overflowed narrow dialogs. | `OverflowBar`: buttons move to a right-aligned second line. Insets shrink on small windows and titles wrap to 2 lines. |
| A7 | `InfoRow` (detail dialogs) | The value was a bare `Text`, so long addresses, warranty text and file paths overflowed. | Label 2/5, value 3/5 of the width, right-aligned and wrapping. |
| A8 | POS | 460 px bill; product tiles used an aspect ratio, so they were too short for a two-line name; the header row, the button row (Hold/Held/Clear/Complete ≈ 420 px) and the total amount could all overflow; the bill had no scroll on short windows. | Responsive bill (340–460 px); tile height fixed at 128 px; header `Wrap`; the button row becomes two rows below 400 px; the total scales down; below 560 px of height the bill scrolls with a fixed-height cart. |
| A9 | Dashboard | Section titles in `Row` + `Spacer`; activity values unbounded; the 5-segment range selector can't wrap; the donut was a fixed 150 px. | Ellipsized titles and values, a horizontally scrollable range selector, a donut that scales to the card, and a shared `ResponsiveGrid`. |
| A10 | `StatCard` (dashboard, ledgers, reports, technicians) | Large amounts split digits across lines in narrow cards. | The value scales down to fit (`FittedBox.scaleDown`); the label is limited to 2 lines. |
| A11 | Ledgers / Reports | 4 (ledgers) or 3 (profit report) stat cards in an unwrapped `Row`; the report list was a fixed 260 px. | `ResponsiveGrid` for the cards; report list 200–260 px; report columns have minimum widths, so wide reports scroll. |
| A12 | Products | The "Tracking" cell is a `Row` of up to 3 pills; the product dialog footer is a fixed ≈600 px `Row`; 3 fields per row in narrow dialogs. | Pills `Wrap`; the footer is two wrap groups (left: archive/history, right: save); fields go 3 → 2 → 1 per row. |
| A13 | New Purchase dialog | The footer `Row` had ≈810 px of fixed widths and overflowed below ~1000 px; line items got 70 px inputs. | Below 900 px: line inputs move under the product name and the footer becomes two rows. The whole dialog scrolls when the window is short. |
| A14 | Inventory → Inspection queue | The product title + pill `Row` couldn't wrap beside 3 fixed decision buttons. | Title/pill `Wrap`; buttons wrap below the details on narrow cards. |
| A15 | Technicians | Aspect-ratio cards (too big in one column, cramped otherwise); the detail dialog stacked a 5-card stats wrap + tabs into 88% height, so the table area went negative on short windows. | Fixed 176 px card height; detail header actions wrap; stats stay on one horizontally scrollable row when they don't fit; the dialog scrolls below 520 px. |
| A16 | Customer / Supplier account dialog | The same height stacking problem in the ledger tab. | Scrolls below 540 px; balance scales down; tabs scrollable; opening/closing totals wrap. |
| A17 | Warranty | Lookup card + tabs needed ≈430 px; a result row had 3 fixed buttons. | Buttons move under the result below 760 px; the page scrolls via A3. |
| A18 | Backup | The "Backup hour / Keep last" `Row` needed ≈414 px inside a ≈342 px card (real overflow at 1024-class widths); two side-by-side card rows never stacked. | `Wrap`; cards stack below 980 px. |
| A19 | Settings | Users tab: a long description `Text` in a `Row` with `Spacer` and a button, with no `Expanded`. 4 prefix fields and 3 sales fields in fixed rows. | `Expanded` text; `ResponsiveGrid` for the field groups. |
| A20 | Login | The first-run setup card (≈570 px) wasn't scrollable, so it overflowed at ≤ 560 px height. | Scrollable. |
| A21 | PDF preview / file browser / pickers / global search | Long printer names in a button; fixed 600–560 px dialog heights; unbounded titles. | Printer label ellipsized with a tooltip; icon buttons on narrow windows; heights clamped to the window; titles ellipsized. |
| A22 | Other dropdowns (21 form fields + 3 plain) | Same root cause as R1/R2. | All use `AppDropdown` / `AppDropdownButton`. |
| A23 | Toasts, confirm/prompt dialogs, startup error screen | Fixed 420 px toast; dialogs not scrollable. | Toast ≤ window width − 32; dialogs scrollable. |

What did **not** change: business logic, services, Hive schema and data, keyboard shortcuts (F2/F3/F4/F8/F9, Ctrl+Enter, Ctrl+K, Ctrl+S, Esc), and features. Nothing is hidden with `ClipRect`, and font sizes are unchanged. Large screens keep the original layout: every adaptive rule only takes effect below its breakpoint.

## 3. Breakpoints (logical px)

| Width / height | Behaviour |
|---|---|
| < 1180 window | Sidebar auto-collapses to icons |
| < 1000 | Tighter page padding (POS, reports, dialogs) |
| < 900 top bar | Icon "New Sale", short date, avatar only |
| < 900 dialog | New Purchase lines/footer stack |
| < 760 | Page-header actions under the title; warranty / inspection buttons below the content |
| < 720 × 560 page | Page scrolls (MinSizeScroll) |
| < 560 bill height | POS bill scrolls, cart fixed at 180 px |

## 4. Automated tests (`test/responsive_test.dart`)

Every `FlutterError` during layout or paint is recorded and fails the test, naming the page, viewport and offending widget. Real fonts (Roboto from the Flutter SDK, standing in for Segoe UI and Consolas) are loaded, so text widths are realistic rather than the test font's square glyphs. The data is seeded with deliberately long names and every badge status.

| Test | Viewports |
|---|---|
| Every page **and every tab** renders without overflow | all 14 |
| POS payment-method dropdown: inside the window, menu items on screen, long option selectable, Complete button visible | all 14 |
| Serial status badges, status filter menu (longest label), serial detail dialog | all 14 |
| Notification bell, badge, panel; every notification inside the window; tapping navigates | all 14 |
| Dialogs and forms: add/edit product, new purchase with a line, purchase detail, customer picker, invoice detail, customer account, receive payment, technician detail, issue material, inspection decision, quotation editor (existing/new), repair detail, receive device, warranty lookup, new user, all 29 reports, global search | 4 smallest + 1920×1080 |
| Sidebar expand/collapse mid-animation frames | 1024×600 |
| Pages and notifications at **115% text size** | 1366×768, 1024×600, 1366×768 @150% |

The 14 viewports are 1024×600, 1280×720, 1366×768, 1440×900, 1600×900 and 1920×1080 at 100%. On top of those:
- 1280×720 @125%, 1366×768 @125%, 1366×768 @150%, 1920×1080 @125% and 1920×1080 @150% (logical sizes 1024×576, 1093×614, 911×512, 1536×864, 1280×720).
- Maximized client areas 911×433 and 1024×529.
- The minimum window, 800×500.

## 5. Verification status

| Check | Who | Result |
|---|---|---|
| Static analysis of the whole app incl. the new test (Flutter 3.41.6 source, flutter_lints, Dart 3.11.4) | developer | ✅ No issues |
| 60 business / scenario / export / PDF tests on Dart 3.11.4 | developer | ✅ 60/60 (business logic unchanged) |
| Windows runner C++ type-check (mingw-w64, Windows SDK + Flutter 3.41.6 engine headers) | developer | ✅ compiles (`-fsyntax-only`); ☐ not built or run on Windows |
| `flutter test` incl. `responsive_test.dart` and `widget_test.dart` | **you (Mac)** | ☐ pending |
| Manual look at the running app at the target sizes | **you** | ☐ pending (needs a non-full-screen desktop for remote inspection, or your own check) |
| Real Windows at 100/125/150% scaling | **you (Windows PC)** | ☐ pending |

## 6. Remaining limitations

- Below about 720×560 logical (for example a 1280×720 screen at 150%, which is 853×480), pages scroll instead of fitting on one screen. This is by design.
- Wide reports and tables on small windows scroll sideways rather than hiding columns.
- Tests use Roboto as a stand-in for Segoe UI. The extra 115% text pass covers the small width difference, but final visual sign-off should happen on Windows.
