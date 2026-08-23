The configurator's install progress no longer reports "one worker image did not
finish successfully" when the image actually seeded fine. A fork install starts
each copy workflow twice -- the page dispatches it and the install merge's own
push trigger fires it -- and their shared concurrency lane cancels one of the
twins while it is still queued. The watcher used to judge only the newest run, so
when the cancelled twin was the newer one it showed a false warning; it now
prefers a successful run of that workflow from the same install before judging.
