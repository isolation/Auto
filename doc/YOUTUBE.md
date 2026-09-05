# YouTube titles on demand

Install `YouTube.pm` in the bot's modules directory and build it using your
installed `buildmod YouTube` (or `auto-buildmod YouTube`) utility, then add this
to your installed `auto.conf`:

```text
module "YouTube";
youtube {
    api_key "your-youtube-data-api-v3-key";
    source_ip "192.0.2.10";
}
```

Replace the example IP with the IPv4 address assigned to your bot's host and
allowed by your Google API key restrictions. Enable YouTube Data API v3 for
the key's project. `source_ip` is optional; omitting it uses normal routing.
When supplied, it must be a non-wildcard IPv4 address. Failed binds fail the
lookup without falling back to another address. Config values are read on each
lookup, so a rehash applies key/address changes to subsequent requests.

With `fantasy_pf ".";`, anyone in a channel can use `.plz`:

```text
<someone> https://youtu.be/ZHVL3z6PXe4
<someone-else> .plz
<bot> YouTube - Bodega Cats [03:59 - Channel Name]
```

The YouTube label retains AdvTitle's IRC colors. Titles and channel display
names come from `snippet`; the duration comes from `contentDetails`, in one
HTTPS request to the YouTube Data API v3 `videos.list` endpoint.

The module silently remembers the last video ID separately for each network
and channel. It accepts HTTP/HTTPS watch URLs on youtube.com (including www,
m, and music), youtu.be links, and YouTube shorts/live/embed links. Timestamps,
share parameters, and fragments do not become part of the ID. Playlist-only,
channel, malformed, and lookalike-domain URLs do not replace the saved video.
If a message contains several valid video links, the last one wins.

No HTTP request is made when a link is posted. Each `PLZ` uses the video saved
when the command arrives; later messages cannot change an in-flight lookup.
The saved ID stays available for repeated lookups, but clears on module unload
or bot restart. Tracking follows Auto's case-insensitive channel naming.
The command is channel-only. With no saved video it sends the requester a
NOTICE: `No recently seen YouTube title.` Errors also go to the requester by
NOTICE. At most one lookup per channel/network runs at a time; additional
requests get a NOTICE. Requests time out after 15 seconds.

Dependencies: `Net::Async::HTTP` 0.45 or later, `IO::Async::SSL`, `JSON::PP`,
and `URI` (including `URI::QueryParam`). HTTPS certificate verification is
enabled; the host needs a working CA trust store. No GData or Twitter library
is needed. Unloading cancels pending requests and removes private HTTP clients.

Run `prove t/*.t`. The YouTube unit tests use synthetic API responses and need
no key. The optional transport test uses a local HTTP server to check real
source binding when the HTTP dependencies are installed. A live Google test
still needs your configured host and key.
