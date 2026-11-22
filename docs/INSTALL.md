# Installing RemoteMirror

Two packages, built on the MacBook with `packaging/package.sh`:

| Package | Mac | Contents |
|---|---|---|
| `dist/RemoteMirror-MacBook.zip` | Apple silicon MacBook | menu bar app (arm64) |
| `dist/RemoteMirror-iMac.zip` | Intel iMac | waiting app (x86_64) |

No Xcode or Swift is needed on the target Macs: each installer signs the app
locally with a self-signed identity ("RemoteMirror Dev", own keychain), so the
macOS permissions you grant survive updates.

## Getting the packages

From the GitHub release page of the (private) repo, logged in:
`https://github.com/andreabarsanti-alt/iMacDisplay/releases` -> download
`RemoteMirror-MacBook.zip` or `RemoteMirror-iMac.zip`, double-click to unzip, then
in Terminal: `cd ~/Downloads/RemoteMirror-MacBook && ./install.sh` (or `RemoteMirror-iMac`).
The installer removes the download quarantine flag from the app it installs.

## Order

1. **Cable:** connect the MacBook (USB-C Ethernet adapter) to the iMac's Ethernet port.
2. **MacBook:** unzip, open Terminal in the folder, run `./install.sh`.
   - sets the cable IP `10.77.0.1` (original settings backed up; asks for your password)
   - installs `~/Applications/RemoteMirror.app`
   - creates the pairing key and puts `RemoteMirror-pairing.key` on the Desktop
     (with `--push-to andrea@10.77.0.2` it is copied to the iMac over SSH instead)
   - asks for Screen Recording and Accessibility and opens the right Settings panes
3. **Copy** `RemoteMirror-pairing.key` to the iMac (AirDrop or USB), next to the iMac installer.
   Treat it like a password: the iMac installer deletes it after importing.
4. **iMac:** unzip, run `./install.sh` (add `--login-item` to start it at login).
   - sets the cable IP `10.77.0.2` (backed up), imports the key, installs the app,
     asks for Accessibility (for Cmd-Tab etc.); allow Local Network if asked
5. **Use:** MacBook menu bar icon -> Start Sharing. The iMac goes full screen by itself.

## Options

| Installer | Option | Effect |
|---|---|---|
| both | `--skip-network` | leave network settings alone |
| both | `--skip-permissions` | only check permissions, don't open Settings |
| both | `--no-launch` | don't start the app at the end |
| MacBook | `--push-to USER@IP` | copy the pairing key to the iMac over SSH |
| iMac | `--pairing-file PATH` | use this pairing file |
| iMac | `--login-item` | start the waiting app at login |
| iMac | `--keep-pairing-file` | don't delete the pairing file after import |

## Uninstall

`./uninstall.sh` in the same package folder, on each Mac:
quits and removes the app and login item, resets its permission entries,
removes the pairing key and the signing identity, and restores the original
network settings from the backup (asks for your password).
Keep parts with `--keep-network`, `--keep-permissions`, `--keep-key`, `--keep-identity`.

## A second MacBook (same iMac)

1. On the first MacBook: `./export-pairing.sh` (in the MacBook package) puts
   `RemoteMirror-pairing.key` on the Desktop.
2. Copy it to the other MacBook next to its `install.sh` (or into Downloads / Desktop).
3. Run `./install.sh` there: it imports the key and deletes the file. Nothing to do on
   the iMac. Only one MacBook on the cable at a time (both use 10.77.0.1).

The MacBook app is universal (Apple silicon and Intel).

## Another iMac

Use the same `RemoteMirror-iMac.zip` and the MacBook's pairing file
(`~/.imacdisplay/psk` on the MacBook; copy it as `RemoteMirror-pairing.key`).
One iMac at a time: the MacBook only accepts the client at `10.77.0.2`.
