# Karcsi's Projects

A small collection of tools I built to solve my own problems — a grind planner, an EXIF metadata inspector, and a photo-to-PowerPoint automator. Different stacks, same idea: useful, fast, no fluff.

Live site: **https://\<username\>.github.io/\<repo-name\>/**

---

## Projects

### 1. Grind Planner — `Index/`
A deterministic day-by-day schedule simulator for crime-sim grinders. Respects cooldowns, passive accrual, and downtime. Pure HTML/JS, runs in any browser, stores settings in `localStorage`.

- Landing page: `Index/index.html`
- The app itself: `Index/calculator.html`
- Intro video iframe: `Index/Grind Planner - Feature Video.html`

### 2. ExifViewer — `Exifviewerproject/`
A native macOS app (SwiftUI) for inspecting the EXIF metadata inside your photos. Camera, lens, aperture, GPS, timestamps — laid out plainly. Local-only, no network.

- Landing page: `Exifviewerproject/index.html`
- Xcode project: `Exifviewerproject/ExifViewer.xcodeproj`
- Build: open in Xcode, press `⌘R`

### 3. Photo Watcher — `Photo Automation/`
A tiny Python watchdog that watches a folder and auto-bundles every new subfolder of photos into a `.pptx` slide deck. Drop photos in, decks fall out.

- Landing page: `Photo Automation/index.html`
- Script: `Photo Automation/photo_watcher.py`
- Install: `pip install -r "Photo Automation/requirements.txt"`
- Run: `python "Photo Automation/photo_watcher.py" <folder-to-watch>`

---

## Repo structure

```
.
├── index.html                          # main landing / project hub
├── README.md
├── Index/                              # Grind Planner
│   ├── index.html                      # marketing page
│   ├── calculator.html                 # the calculator app (self-contained)
│   └── Grind Planner - Feature Video.html   # intro video (embedded in hero)
├── Exifviewerproject/                  # ExifViewer (macOS app)
│   ├── index.html                      # marketing page
│   ├── ExifViewer.xcodeproj/           # Xcode project
│   └── ExifViewer/                     # SwiftUI source
└── Photo Automation/                   # Photo Watcher (Python)
    ├── index.html                      # marketing page
    ├── photo_watcher.py                # the script
    └── requirements.txt                # Python deps
```

---

## Deploy on GitHub Pages

1. Push this repo to GitHub.
2. Repo **Settings → Pages → Source**: `main` branch, `/` (root).
3. The site will be live at `https://<username>.github.io/<repo-name>/` within a minute or two.

All internal links are relative, so no config is needed regardless of the repo name.

---

## License

Personal / open-source-ish. Fork it, break it, improve it.

Not affiliated with or endorsed by Rockstar Games, Take-Two Interactive, or Apple. All trademarks belong to their respective owners.
