# ADR-0015: The cable's limits: a gate before the takeover, a size in the driver, a count per connection

**Status:** accepted · **Date:** 2026-11-13 (decided with the owner after an
analysis of the demo's cable and an independent review that cut the plan
down; threat model SR-03, SR-04, SR-32, SR-40).

## Context

Action Cable (8.1.4.1) runs every socket of the one Puma process on one
event loop and hands each command to a pool of four threads with an
unbounded queue. On the demo, measured on 2026-11-13 (handshakes only on the
public host; everything else on a local Puma with the container's limit of
1,024 open files):

- a socket holds one of Puma's files, about 40 KB, and stays as long as the
  client wants: about 1,008 idle sockets stopped Puma accepting (`EMFILE`)
  and `/up` stopped answering; one address gets there in about 17 minutes at
  the edge's 60 requests a minute, 17 addresses in one;
- a message may carry 64 MiB (websocket-driver's default, since Action
  Cable passes no limit), buffered whole: 32 MiB cost the server 0.94 s of
  CPU, 161 MB of peak memory and 32 MB of log, and the socket stayed open;
- only a subscription counts against the edge's minute: 5,000 other
  commands on one socket delayed another page's subscription from 0.03 s to
  1.5 s, and 1,000 commands of 16 KiB wrote 15.7 MB of log, since Action
  Cable writes a refused command whole into its line;
- a handshake with no version and no key is read as hixie-75 (2010), whose
  parser costs about 90 times the CPU per byte on that one loop;
- Solid Cable kept every broadcast (a conversation's replies, spans and
  deletion word) a day, past the visitor's `/apagar`.

Rails offers no setting for any of these.

## Options

- **Where the socket caps refuse.** (a) In `connect`, after Action Cable
  took the socket over, as first planned; (b) in a gate in front of Action
  Cable, before the takeover. Measured on (a): from one address, 40
  handshakes gave 20 sockets and 20 refusals, and the server still held 43
  files 30 s later, the client keeping every socket and answering no close
  frame; a refusal after the takeover holds the socket as long as the client
  wants, so the caps would not protect the files. Measured too: Action
  Cable's own list of connections keeps an entry now and then of a socket
  that closed as it opened (21 of 300 quick open-and-close), so it cannot be
  what the caps count.
- **The message size.** (A) A `prepend` on `WebSocket::Driver.rack` that
  gives the driver Action Cable builds a `max_length`; (B) a byte quota per
  connection kept by the gate; (C) a size check in the connection's
  `receive`, after the driver has buffered the whole message.
- **The command count.** An override of `on_message`, or of `receive`, or a
  limit in each channel.

## Decision

- **A gate at `/cable`** (`ApplicationCable::Gate`, mounted in
  `config/routes.rb`; Action Cable's own mount is off). Before the takeover it
  answers 426, with `Sec-WebSocket-Version: 13`, to any other version or none
  (hixie-75 and -76), and 400 to a handshake without a key; the key's 16
  bytes are not checked, since websocket-driver hashes whatever it gets. A
  request that asks for no upgrade goes to Action Cable as before.
- **The socket caps in the gate, option (b):** 500 sockets per process and
  20 per source (the client's address as the edge counts it, SR-36). A
  socket counts from the takeover, by the socket the gate saw Action Cable
  take, until Action Cable closes it. Past a cap the gate answers 429 (the
  source's) or 503 (the process's), plain HTTP: the page's cable client tries
  again a few seconds later by itself, which the trace page, with no polling,
  needs. Behind Thruster, as in the container, a refusal holds none of
  Puma's files; measured with the branch's code: 1,230 handshakes gave 500
  sockets, 730 refusals, `/up` 200 and no `EMFILE`.
- **16 KiB a message, option A** (the owner: "Prefiro a A"). The `prepend`
  merges `max_length` into the options of every driver `WebSocket::Driver.rack`
  builds, keeping a smaller limit a caller asks for; Action Cable is the one
  caller. A longer message closes the socket with 1009 from the frame's
  header (32 MiB: closed in 0.08 s, no CPU, memory or log). A page's command
  is about a hundred bytes. `Driver.rack` and `max_length` are
  websocket-driver's public API; the `prepend` goes when Rails ships a
  setting for it.
- **20 commands a minute per connection, in an override of `on_message`.**
  It is where every message the socket reads arrives, on the event loop,
  before Action Cable's message buffer (which holds commands until the
  connection opens, without bound) and its worker pool; `receive` comes after
  the buffer. The 21st command closes the connection with `reconnect: false`.
  A page sends one or two (a subscribe, and one more if it opened before the
  welcome); the client's guarantor sends a subscribe again every 0.5 s while
  the server has not confirmed, so a page reaches 20 only if a confirmation
  is 10 s late (0.03 s normally, 1.5 s under the flood above). `on_message`
  is marked `:nodoc:`, so a spec pins its source and its caller's and breaks
  if Rails changes either. Each cable log line is cut at 2 KB, after its
  trace tokens are filtered. Measured with the branch: 5,000 commands now
  delay another page's subscription 0.13 s, and with 1,000 of 16 KiB the
  whole run wrote 46 KB of log, no line over 2 KB.
- **Connections that closed as they opened.** Action Cable runs a socket's
  opening and its closing as two tasks of its worker pool. The opening adds
  the connection to the server's list at its end, and subscribes its
  internal channel, whose callback holds it, through a pool of threads with
  no order against the closing's unsubscribe. A script that opened and
  closed sockets at once left connections held in both until the process
  ended. Added at the owner's word once measured: an override of the
  private `handle_open` takes out of the list a connection whose socket is
  gone by the end of its opening, and the connection subscribes no internal
  channel, whose only use is a remote disconnect this app never makes (the
  list alone left the subscription: review finding R2, and another session
  reported it). Specs pin the four methods. On a local Puma with the pub/sub
  subscribing at once, as Solid Cable does, 1,000 sockets opened and closed
  at once left 52 connections in the list and 58 alive before, none after.
- **Origin:** `allow_same_origin_as_host` is off, so the cable accepts the
  public origin alone and no longer leans on production's host check.
- **Solid Cable keeps a copy 5 minutes, and a recurring task deletes every
  copy past them every 5** (`config/recurring.yml`), so a copy outlives its
  broadcast by about 10 minutes; SR-32 names that exception rather than
  `/apagar` deleting the copies. Solid Cable's own `TrimJob` deletes 100 a
  run, fewer than a conversation of ten turns writes, so the task deletes
  them in batches through the gem's `trimmable` scope.

## Consequences

- The caps count per process: if Puma ever runs workers, each has its own
  (design §10). The numbers leave about 500 of Puma's 1,024 files to
  everything else.
- A crowd of sources can still fill the 500 (threat model R8); the pages
  then retry and the chat falls back to polling while a turn waits.
- What the slice left out, with its reasons, is in its pull request.
