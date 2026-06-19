module lvci-toimages-runner

go 1.26.3

// The runner is pure stdlib: it shells out to the `lvctl` binary (built
// separately from _ni/labview/lvctl) to render each VI, so it has no module
// dependencies of its own.

