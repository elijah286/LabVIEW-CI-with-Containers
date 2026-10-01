Unit Tests now run LUnit in the Linux worker as well. Installing Unit Tests with
Linux adds unit-tests-linux-container.yml and run-unit-tests.sh, which publish a
Linux report under unit-tests/<sha>/linux/ with the commit status
CI / Unit Tests (Linux); the dashboard shows the Windows / Linux split and the
report's platform toggle switches between them. Keep -Headless as the last
argument of any unitTests command: override, since Linux LabVIEWCLI ignores
anything after it.
Linux worker builds also no longer fail on VIPM packages whose version carries
a revision suffix (such as jki_rsc_toolkits_palette 1.1-1).
