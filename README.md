# Wall Framer (SketchUp extension)

A teaching wall-framing extension for the DMACC Construction Technology program. Students place walls on levels and frame them in job-site order using pop-ups. The sequence is plates, opening layout with a tape, opening units, stud layout and commons, then interlocking double top plates. Every board comes out of a material yard. Inspections, a manual takeoff check, shop drawings and answer-key grading are built in.

## Install (first time)

1. Download the newest `.rbz` from [`releases/`](releases/).
2. In SketchUp, go to Extensions → Extension Manager → Install Extension and pick the `.rbz` file.

## Updates

Wall Framer checks for a new version every time SketchUp starts. When one is posted, it asks "Update now?", then downloads, installs and reloads itself. There's no uninstall or restart.

- To check by hand, go to Extensions → Wall Framer → Check for Updates.
- If you installed a `.rbz` over the top by hand, go to Extensions → Wall Framer → Reload After Update.

The update address is built in. It points at `version.json` in this repo:

```
https://raw.githubusercontent.com/adamnegrete-lab/Wall-Framer-Ext./main/version.json
```

## Repo layout

- `src/` holds the extension source. `dmacc_wall_framer.rb` is the loader, and `dmacc_wall_framer/` holds the code, the dialogs and the icons.
- `releases/` holds the built `.rbz` files.
- `version.json` tells every installed copy what the newest version is.
- `test/` holds tests that run without SketchUp, using plain Ruby and a mock SketchUp API.
- `docs/` has the bunkhouse test plan (A-1) and its instructor answer sheet (I-1).
- `scripts/build.sh` packages a release and updates `version.json`.
- `scripts/test.sh` runs every test suite.

## Publishing a new version

1. Bump `VERSION` in `src/dmacc_wall_framer/version.rb`.
2. Run `scripts/test.sh`.
3. Run `scripts/build.sh "What changed"`.
4. Commit and push to `main`. Installed copies pick up the new version on their next start.
