# Integration Test TODO

- [x] Add a manually triggered, live-provider browser and SearxNG integration suite with a tool-safe factual lookup.
- [ ] Run the live browser and web-search suite in the Docker-enabled CI environment and capture non-sensitive latency and success evidence.
- [ ] Diagnose and correct any observed browser-agent or SearxNG integration failure.
- [x] Remove the temporary live-provider credential after the validation and report results.
- [x] Execute the bounded live browser-search workflow twice; both runs reached readiness but returned HTTP 500 before non-sensitive success evidence could be captured.
- [x] Remove the temporary GitHub Actions live-provider credential after the terminal workflow result and confirm its absence.
- [x] Preserve hidden live-test diagnostics artifacts and emit only classified exception names to container logs for a future failure investigation.
