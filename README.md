# ScribeSync

Sync Kindle Scribe notebooks to your computer, convert them to EPUB and PDF, all
locally through a USB connection. No internet required. You can use your Scribe
in airplane mode if you want and use this to export your notebooks (also backing
them up -- the raw nbk files).

I accept code contributions, although I intend to keep this script minimal since
I do rely on it for my handwritten digital notes on my offline Scribe.

> Kindle is an Amazon brand.

## Features

- Automatic Kindle Scribe detection and mounting
- MD5-based change detection (only replaces and converts changed notebooks)
- Parallel conversion using Calibre
- Creates symlinks to converted notebooks in `~/Notebooks`
- Notebook labeling system for custom names

## Dependencies

| Package                  | Purpose                                                      |
| ------------------------ | ------------------------------------------------------------ |
| Calibre                  | Conversion (ebook-convert, calibre-debug)                    |
| Calibre KFX Input Plugin | Convert .nbk files (Preferences → Plugins → Get new plugins) |
| go-mtpfs                 | MTP device mounting through FUSE                             |
| FUSE + util-linux        | Unmounting (`fusermount3` / `fusermount`), `mountpoint`        |
| jq                       | JSON processing                                              |
| lsusb                    | Device detection (usually pre-installed)                     |

`udisks`/`udisksctl` mounts block devices, not MTP devices. This script uses
`go-mtpfs`: no `jmtpfs`, GIO/GVfs, or D-Bus session is needed. Run it as your
normal user with USB access and FUSE support, not with `sudo`.

The script creates a private temporary mount and attempts to unmount it on
completion, errors, or interruption. Close or unmount other MTP clients first
(including desktop/file-manager mounts); they cannot share the device.

On NixOS, install the commands with:

```nix
environment.systemPackages = with pkgs; [ go-mtpfs usbutils jq calibre util-linux ];
# MTP udev rules for normal-user USB access:
services.udev.packages = [ pkgs.libmtp ];
```

NixOS normally provides the FUSE helpers in `/run/wrappers/bin`; ensure
`fusermount3` or `fusermount` is on your PATH. GVfs does not need to be enabled.

## Installation

```bash
# Clone or download this repository
git clone https://github.com/Cosipa/ScribeSync-Linux
cd ScribeSync-Linux

# Copy and edit configuration
cp config.ini.example config.ini
# Edit config.ini to set your preferences
```

## Configuration

Edit `config.ini`:

```ini
# Absolute path to your assets folder (used for symlink creation)
AssetsFolder="/home/user/ScribeSync-Linux/sync_data/pdf"

# Optional go-mtpfs device-ID regex (manufacturer/product/serial)
# Default: (?i)scribe. Use your device's serial if multiple Scribes are connected.
# MtpDeviceFilter="YOUR_SCRIBE_SERIAL"
```

## Notebook Labels

Create `notebook_labels.json` in the project root to give notebooks custom
names:

```json
{
  "f09674ee-16cf-7830-6544-148244f68e43": "Calculus Notes",
  "9fa52d48-5958-58dc-61e9-12e6fa813fec": "Physics Study"
}
```

## Usage

```bash
# Run the sync
./scribeSync.sh

# Open a specific notebook interactively (after first sync)
./nb-open.sh
```

The script will:

1. Detect and mount your Kindle Scribe
2. Download notebooks and update changed backups in `sync_data/notebooks/`
3. Unmount the device if the script mounted it
4. Convert local copies to EPUB and PDF in `sync_data/epub/` and `sync_data/pdf/`
5. Create symlinks in `~/Notebooks/` with the proper notebook labels you set.

MTP has no remote checksum API, so each `nbk` is downloaded to a temporary file
for comparison. Failed transfers leave existing backups untouched. Missing or
outdated EPUB/PDF exports are retried even when the notebook backup is unchanged.

Firmware folder names ending in `!!PDOC!!notebook` are normalized to bare UUIDs,
preserving existing backups and labels. The script sets `GOGC=off` only for the
short-lived go-mtpfs process to work around a file-descriptor lifetime bug in
v1.0.0's non-Android reader; this can increase its memory use during a sync.

## Troubleshooting

**Device not detected**

- Ensure Kindle Scribe is connected via USB
- Try: `lsusb | grep -i scribe`

**Mount fails**

- Verify `go-mtpfs`, `mountpoint`, and `fusermount3` or `fusermount` are installed
- Close/unmount other MTP clients that may hold the device (file manager, Calibre)
- Check USB permissions and that `/dev/fuse` is available to your user
- The script prints the go-mtpfs log if mounting fails or takes longer than 30 seconds
- If the log says no device matched, adjust `MtpDeviceFilter` in `config.ini`
- Test manually (in a separate terminal, stop with the unmount command):

  ```bash
  mkdir -p "$HOME/Scribe-MTP"
  GOGC=off go-mtpfs -android=false -dev '(?i)scribe' "$HOME/Scribe-MTP"
  # In another terminal:
  fusermount3 -u "$HOME/Scribe-MTP" # or fusermount -u
  ```

**Notebook storage not found**

- Confirm the connected device is your Scribe and contains notebooks
- The script discovers `.notebooks` inside the device's storage; it does not
  depend on the storage being named `Internal Storage`

**Conversion fails**

- Verify Calibre is installed: `ebook-convert --version`
- Check Calibre plugins: `calibre-debug --run-plugin "KFX Input"`

## License

MIT License
