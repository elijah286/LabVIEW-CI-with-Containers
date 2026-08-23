Every vendored workflow file now carries a tooling-version stamp, so each update
rewrites every workflow file and the update push makes GitHub (re)register them.
This heals repositories -- typically fork installs whose pipeline was pushed while
Actions was still disabled -- where dispatch-only workflows like Reconfigure
existed on the default branch but were never registered, so the dashboard's "Save
monitored files" and container-update buttons failed with HTTP 404 no matter what
token was supplied. The Dependencies and Configure pages now also tell this case
apart from a real token problem and say exactly how to fix it.
