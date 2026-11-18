# USB Barcode / QR Scanner — 17 Nov 2026

## What is supported
Standard USB scanners in **keyboard (HID) mode** — the factory default of
almost every 1D/2D scanner. Windows sees them as a keyboard, so:

* no driver, no internet, no camera and no extra software is needed;
* the app works fully offline with them.

Serial-port (COM / "USB virtual COM") mode and Bluetooth SPP mode are **not**
supported. Set the scanner to keyboard / HID mode (see its manual's setup
barcodes).

## How the POS handles a scan
* A scan is recognised by its speed: characters at most 40 ms apart
  (scanners type every 1-15 ms) and at least 4 characters, ending with the
  suffix key. Normal typing is slower and is never treated as a scan.
* It works **whichever field has focus**, or none: the scanned characters are
  removed again from the field they went into (for example the Paid amount),
  and the Enter/Tab is not passed on.
* The code is looked up exactly, in this order: company barcode / QR text,
  printed label (internal code), serial number of an individual unit, SKU.
  Upper/lower case and spaces do not matter.
* Found product → added to the bill (or one more of it). Serial number → that
  exact unit is added; a unit already on the bill or not in stock is refused
  with a message. If the same serial exists under two brands and both are in
  stock, you are asked which unit it is. Scanning the product barcode of a
  serial-tracked product opens the unit picker.
* Unknown code → a red message `Unknown code "…"`; nothing is added and nothing
  is guessed from partial matches.
* The same code again within 0.7 s (a double read) is ignored with a short
  message; scanning it again later adds one more.
* Typing by hand is unchanged: type a name/SKU to filter, Enter adds the single
  match. Typing while no field has focus goes into the search box.

## Settings → Printing & Labels → Barcode / QR scanner
| Setting | Default | When to change |
|---|---|---|
| Key the scanner sends after the code | Enter or Tab (automatic) | "No suffix" if the scanner sends nothing after the code; Enter-only / Tab-only to be strict |
| Max time between characters | 40 ms | Raise (e.g. 60-80) if scans are typed into the search box instead of being added (slow scanner / slow PC) |
| Shortest code | 4 | Lower if you use very short codes |
| Ignore same code again within | 700 ms | 0 turns it off |

## What was tested — and what was not
* Tested (developer): the detection logic (`test/scanner_test.dart`, 14 tests,
  passed), code lookup, settings. POS widget tests that send real key events
  through Flutter's keyboard pipeline (`test/scanner_pos_test.dart`, 7 tests)
  must be run on your machine (`bash tool/run_tests_mac.command`).
* **Not tested: a physical USB scanner.** Compatibility with real hardware is
  not claimed until it has been tried. Checklist for the first real test, on
  Windows:
  1. Open Notepad and scan a label: the code must appear followed by a new line
     (that confirms keyboard mode and the Enter suffix).
  2. POS, scan field focused: scan a product label → one line added, field empty.
  3. Click the Paid field, scan → item added, Paid amount unchanged.
  4. Click an empty area, scan → item added.
  5. Scan the same label 3 times quickly, then once more after 2 s.
  6. Scan a serial-number sticker of a unit in stock.
  7. Scan an unknown barcode → red message only.
  8. Type a product name by hand → list filters normally.
  9. Unplug the network cable → repeat 2.
  If step 2-4 put the code in the search box instead of adding it, raise
  "Max time between characters" to 80 ms.
