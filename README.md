# doomsday

Tool to automatically nuke a macOS system on a scheduled basis.

UPDATE: This script is outdated and may no longer work as expected.

<img src="static/avatar.jpg" />

## Why

- Enforce a habit of never relying on hardware.
- Enforce a habit of always having the workstation setup scripted.
- Enforce that the latest software is up to date and that nothing that was unintentionally installed on the OS.

## Objectives

- It should be able to fully nuke and clean my macOS workstation.
- It should be able to schedule a nuke and visually show it when time is closing in.

## How

- https://www.jamf.com/blog/reinstall-a-clean-macos-with-one-button/
- https://grahamrpugh.com/2018/03/26/reinstall-macos-from-system-volume.html
- https://github.com/munki/macadmin-scripts

## API

```sh
doomsday <command> [options]
```

#### `set [days]`

Arms doom to trigger in `days` days. Defaults to `30` and refuses schedules
longer than `366` days.

#### `whatsup`

Prints the current state as key/value output, including status, doom time,
cryo target, remaining time, and the last doom attempt when present.

#### `abort`

Aborts any armed doom and clears the due-run marker.

#### `doom [--yes] [--target path] [--skip-cryo] [--fetch-installer] [--installer app] [--force] [--no-countdown]`

Runs preflight, freezes the environment with cryo, then invokes Apple's
`startosinstall --eraseinstall` reinstall flow.

Unless `--yes` is provided, it prompts for a destructive confirmation phrase.
`--target` overrides the cryo target, `--installer` points at a specific macOS
installer, `--fetch-installer` downloads one if needed, `--force` overrides
power and disk-space preflight failures, and `--no-countdown` skips the final
10 second countdown. `--skip-cryo` requires `--force`.

#### `tick`

Checks armed doom state, sends threshold notifications, and opens Terminal for
the scheduled doom when the deadline is due.

#### `doctor`

Prints diagnostics as key/value output, including version, state directory,
cryo availability, installer availability, AC power, and FileVault state.

#### `install-launchd [--allow-usb-agent]`

Installs a per-user LaunchAgent that runs `doomsday tick` hourly and at login.
It refuses LaunchAgents that point at removable volumes unless
`--allow-usb-agent` is supplied.

#### `uninstall-launchd`

Unloads and removes the LaunchAgent.

#### `help`

Prints usage.

#### `version`

Prints the doomsday version.

### Environment

- `DOOMSDAY_STATE_DIR`: state and log directory. Defaults to
  `~/.local/share/doomsday`.
- `DOOMSDAY_CRYO_TARGET`: default cryo target. Defaults to `/Volumes/CRYO`.
- `DOOMSDAY_INSTALLER`: explicit macOS installer app path.
- `DOOMSDAY_FULL_INSTALLER_VERSION`: version used by `--fetch-installer`.
- `DOOMSDAY_VOLUME_OWNER`: Apple Silicon Volume Owner user for
  `startosinstall`.
