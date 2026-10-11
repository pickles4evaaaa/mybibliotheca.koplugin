# MyBibliotheca KOReader Highlights 2.0.1

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
password. Setup also offers **Auto-push highlights (like progress sync)**,
which is off by default. You can change it later with **Auto-push highlights**
in the MyBibliotheca menu. Existing connection settings
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
4. With Wi-Fi connected, uploads happen after ten seconds of reading inactivity
   following an edit. More edits or page turns postpone that upload so quick
   interactions are batched together.
5. Sleeping or waking the device also checks for pending highlights, using
   KOReader's configured network behavior like automatic progress sync. Closing
   the book or disconnecting Wi-Fi sends pending highlights if still connected.
6. Offline highlights remain pending. Continue reading after connecting, wake
   the device, or reopen that book to send them.

For an immediate upload with a visible success or failure message, choose
**MyBibliotheca → Send this book's highlights** while the book is open. Automatic
uploads run without a popup; they do not bypass the failed-upload cooldown
described below. View the annotations on the linked book in MyBibliotheca.

## Auto-push and power use

Auto-push follows KOReader's progress-sync lifecycle and adds a debounced
highlight-edit trigger:

- Highlight or note edits schedule a single upload after ten seconds. Further
  edits and page turns restart that delay. These uploads use existing Wi-Fi.
- Book opening and wake schedule a check after one second. Sleep checks pending
  changes immediately. These checks use KOReader's normal network connection
  flow and can turn on Wi-Fi or prompt according to its network settings.
- A network connection schedules a check after half a second. Before Wi-Fi
  disconnects or the book closes, pending highlights are sent if connected.
- Disabling auto-push, sleeping, or closing the reader cancels outstanding idle
  tasks. A clean book does not schedule uploads on page turns or turn on Wi-Fi.

For unattended sleep/wake syncing, set KOReader's **Action when Wi-Fi is off**
to **Turn on** where the device supports it, as with automatic progress sync.
The plugin does not change that global setting for you.

There is no repeating polling timer or background worker. At most one deferred
upload task exists per open book; an edit is not itself a network request.
When offline, changes remain in the book's normal KOReader settings. Closed
books are not scanned or uploaded in the background.

After a failed automatic upload, attempts are limited to once every thirty
seconds. Further page turns schedule another opportunity after that cooldown;
book-open, sleep/wake, and network events also retry pending changes. Manual
sending can retry immediately and uses KOReader's usual connection flow.

For low RAM use, the plugin reads KOReader's existing annotations and creates
only one upload batch of up to ten items at a time, rather than copying all
highlights into a separate export tree. It stores only a pending flag and a
digest per book. Unchanged content skips uploading; changed books send their
current highlights and notes in batches using the existing annotation IDs.
Failed batches remain pending, and a retry resends the book's highlights.
This endpoint does not receive deletion requests when local highlights are
removed.

This event-driven approach batches reading-time work and only requests a
connection for pending uploads at book opening or sleep/wake. Uploads still use KOReader's synchronous HTTP API, so book
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
idle scheduling, sleep/wake and connection events, offline persistence,
retries, network failure checks, cancellation of stale callbacks, and
preservation of existing settings and reader data during updates and sync. Run
`luac -p main.lua _meta.lua tests/test_sync.lua` to check Lua syntax. These checks
do not replace testing on a KOReader device.
