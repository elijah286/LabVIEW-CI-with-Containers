Running CI on a fresh fork of a configured repository now works on the first
try. A fork copies the workflows but never the worker container images, so every
container activity used to fail on an opaque "manifest unknown" pull error. The
dependency gate now detects that the worker image has never been built, starts
the Build LabVIEW CI Image run itself, waits for it (a first build takes 80-100
minutes), and then continues. When it cannot start the build automatically, the
job stops up front with instructions instead of a doomed pull, the commit status
reads "Worker image unavailable - build it via Configure Workers" rather than a
generic activity failure, and a pinned container tag that was never published is
reported as a configuration error. Applies the same on any repository whose
first worker build never ran.
