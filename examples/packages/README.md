# Stela Package Examples

This folder contains example `stela.pkg` manifests:

- `math_pkg/`: simple library package (`kind=lib`, `major=1`)
- `app_pkg/`: app package depending on `math_pkg` via a local path (`dep=math|../math_pkg|HEAD|1`)

To use these with `stela`, each package directory should be initialized as a Git repository.
