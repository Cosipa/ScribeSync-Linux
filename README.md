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
- MD5-based change detection (only syncs changed notebooks)
- Parallel conversion using Calibre
- Creates symlinks to converted notebooks in `~/Notebooks`
- Notebook labeling system for custom names

## Dependencies

| Package                  | Purpose                                                      |
| ------------------------ | ------------------------------------------------------------ |
| Calibre                  | Conversion (ebook-convert, calibre-debug)                    |
| Calibre KFX Input Plugin | Convert .nbk files (Preferences → Plugins → Get new plugins) |
| jmtpfs                   | MTP device mounting                                          |
| jq                       | JSON processing                                              |
| lsusb                    | Device detection (usually pre-installed)                     |

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
2. Copy changed notebooks to `sync_data/notebooks/`
3. Convert to EPUB and PDF in `sync_data/epub/` and `sync_data/pdf/`
4. Unmount the device
5. Create symlinks in `~/Notebooks/` with the proper notebook labels you set.

## Troubleshooting

**Device not detected**

- Ensure Kindle Scribe is connected via USB
- Try: `lsusb | grep -i scribe`

**Mount fails**

- Check if `/mnt/MTP` exists: `ls -la /mnt/MTP`
- Try manual mount: `jmtpfs /mnt/MTP`

**Conversion fails**

- Verify Calibre is installed: `ebook-convert --version`
- Check Calibre plugins: `calibre-debug --run-plugin "KFX Input"`

## License

MIT License
