# MyBibliotheca KOReader Highlights 2.0

This KOReader plugin sends highlights and notes from the currently open book to
MyBibliotheca. It uploads annotations directly to the configured MyBibliotheca
server and does not use Readwise.

## Install

Copy the complete `mybibliotheca.koplugin` directory into KOReader's `plugins`
directory, then restart KOReader. The installed path should end with
`koreader/plugins/mybibliotheca.koplugin/main.lua`.

## Update without resetting data

Exit KOReader, replace the files inside the existing
`plugins/mybibliotheca.koplugin` directory, and restart KOReader. The update
package contains plugin code and documentation, not device settings or books.
Keep KOReader's `settings/mybibliotheca.lua` file and book sidecar (`.sdr`)
directories in place.

Version 2.0 reads the same settings file as the previous version. It preserves
your endpoint, username, saved sync key, and other settings. Auto-push stays off
until you enable it; subsequent updates retain your chosen setting. If you
reopen Configure connection, leaving the password blank keeps the saved key
when the username is unchanged.

Sync adds its own pending flag and digest to book settings. It does not erase
highlights, notes, bookmarks, reading progress, or other book metadata.

## Configure

Open a book in KOReader and select **MyBibliotheca** from the reader menu, then
choose **Configure connection**. For the hosted MyBibliotheca service, use:

- Server URL: `https://mybibliotheca.org/notes`
- Username and password: the separate KOReader sync credentials created in
  MyBibliotheca Settings

The plugin stores the KOReader sync key on the device, not the plaintext
password. Setup also offers **Auto-push on book close (existing Wi-Fi only)**,
which is off by default. You can change it later with **Auto-push highlights
(existing Wi-Fi only)** in the MyBibliotheca menu. Existing connection settings
are preserved when upgrading.

To upload manually, open the book and choose **Send this book's highlights**.
The corresponding MyBibliotheca book must be linked to the KOReader document to
show its annotations on that book page.

## Sending workflow

1. Open a book. If you have already configured the plugin, keep your existing
   connection settings. Otherwise, use **MyBibliotheca → Configure connection**
   with the endpoint and KOReader sync credentials listed above.
2. Enable auto-push in setup or the MyBibliotheca menu.
3. Read and create highlights or notes normally.
4. With Wi-Fi connected, close the book by returning to KOReader's file browser.
   The plugin sends the book's highlights and notes automatically. Putting the
   device to sleep does not trigger an upload.
5. If you closed the book offline, reopen that book while connected to send
   pending highlights. A network connection event while the book is open also
   triggers a pending upload.

For an immediate upload with a visible success or failure message, choose
**MyBibliotheca → Send this book's highlights** while the book is open. Automatic
uploads run without a popup; they do not bypass the failed-upload cooldown
described below. View the annotations on the linked book in MyBibliotheca.

## Auto-push and power use

Auto-push batches highlights when you close a book, provided Wi-Fi is already
connected. It also checks for pending uploads when a book is opened or KOReader
reports a network connection. It never turns on Wi-Fi or asks you to connect.
There are no polling timers, background workers, or uploads on every highlight
or page turn, and it does not delay sleep to sync.

When offline, changes remain in the book's normal KOReader settings. Reopen that
book while connected to upload them, or use manual sending. Closed books are
not scanned or uploaded in the background. After a failed automatic upload,
the plugin waits at least five minutes before another book-open, connection, or
book-close event can retry; there is no timed retry. Manual sending can retry
immediately and uses KOReader's usual network connection flow.

For low RAM use, the plugin reads KOReader's existing annotations and creates
only one upload batch of up to ten items at a time, rather than copying all
highlights into a separate export tree. It stores only a pending flag and a
digest per book. Unchanged content skips uploading; changed books send their
current highlights and notes in batches using the existing annotation IDs.
Failed batches remain pending, and a retry resends the book's highlights.
This endpoint does not receive deletion requests when local highlights are
removed.

This event-driven approach minimizes extra work and avoids enabling the Wi-Fi
radio just for sync. Uploads still use KOReader's synchronous HTTP API, so book
closing can pause while requests complete. Automatic requests use shorter
timeouts (3 seconds for a block, 5 seconds total per request); manual requests
retain the existing 10/30-second limits. Power and memory savings have not been
measured on physical e-readers.

## Compatibility

This is a KOReader Lua plugin and requires a KOReader build with third-party
plugin support, the reader annotation APIs, and network access enabled. It is
not tied to a particular e-reader model; available installation paths depend on
the device and KOReader build. Device models and KOReader versions have not yet
been documented as individually tested. The plugin requires an HTTPS server
endpoint.

## Development checks

Run `lua tests/test_sync.lua` for mocked setup, batching, change detection,
offline persistence, retries, network failure checks, and preservation of
existing settings and reader data during updates and sync. Run
`luac -p main.lua _meta.lua tests/test_sync.lua` to check Lua syntax. These checks
do not replace testing on a KOReader device.
