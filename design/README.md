# Icon source art

The ring + cursor glyph used for the app icon and menu-bar icon.

| File | What it is |
|------|------------|
| `icon-glyph.json` | **Source of truth** for the app icon. An array of `{x, y, color}` pixels (64×64): white ring + cursor with a `#202018` halo on transparent. The `AppIcon` PNGs were generated from this. |
| `icon-master-64.png` | 64×64 render of `icon-glyph.json`. The master the `AppIcon.appiconset` sizes are scaled from. |
| `menubar-template-36.png` | 36×36 black-on-transparent **template** silhouette (no halo) for the menu bar. macOS auto-tints it light/dark. Source for `MenuBarIcon.imageset`. |
| `icon.aseprite` | Aseprite working file (rough). Note: the shipped art was finalized in `icon-glyph.json`, so prefer that for edits. |

## Regenerating the app icon PNGs from the glyph

```python
import json
from PIL import Image
data = json.load(open('design/icon-glyph.json'))
master = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
px = master.load()
for q in data:
    c = q['color'].lstrip('#')
    px[q['x'], q['y']] = (int(c[0:2],16), int(c[2:4],16), int(c[4:6],16), 255)

sizes = [(16,'icon_16'),(32,'icon_16@2x'),(32,'icon_32'),(64,'icon_32@2x'),
         (128,'icon_128'),(256,'icon_128@2x'),(256,'icon_256'),(512,'icon_256@2x'),
         (512,'icon_512'),(1024,'icon_512@2x')]
out = 'copy-on-select/Assets.xcassets/AppIcon.appiconset'
for px_size, name in sizes:
    master.resize((px_size, px_size), Image.NEAREST).save(f'{out}/{name}.png')
```

Use `Image.NEAREST` to keep the pixel-art edges crisp.
