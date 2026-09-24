# MyBibliotheca KOReader Highlights

This KOReader plugin sends highlights and notes from the currently open book to
MyBibliotheca. It uploads annotations directly to the configured MyBibliotheca
server and does not use Readwise.

## Install

Copy the complete `mybibliotheca.koplugin` directory into KOReader's `plugins`
directory, then restart KOReader. The installed path should end with
`koreader/plugins/mybibliotheca.koplugin/main.lua`.

## Configure

Open a book in KOReader and select **MyBibliotheca** from the reader menu, then
choose **Configure connection**. For the hosted MyBibliotheca service, use:

- Server URL: `https://mybibliotheca.org/notes`
- Username and password: the separate KOReader sync credentials created in
  MyBibliotheca Settings

The plugin stores the KOReader sync key on the device, not the plaintext
password. To upload, open the book and choose **Send this book's highlights**.
The corresponding MyBibliotheca book must be linked to the KOReader document to
show its annotations on that book page.

## Compatibility

This is a KOReader Lua plugin and requires a KOReader build with third-party
plugin support, the reader annotation APIs, and network access enabled. It is
not tied to a particular e-reader model; available installation paths depend on
the device and KOReader build. Device models and KOReader versions have not yet
been documented as individually tested. The plugin requires an HTTPS server
endpoint.