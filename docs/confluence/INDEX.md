# Confluence Upload Guide — SEHC AI Gateway

This folder holds the SEHC AI Gateway documentation, split into pages for Confluence.
Upload each `.md` as its own page (in order), and attach the referenced SVG image(s)
to the matching page.

## Page hierarchy (suggested)

```
SEHC AI Gateway (space / parent page)
├── 00 · Overview            ← 00-overview.md          [img: diagram-as-is-to-be.svg]
├── 01 · Architecture        ← 01-architecture.md      [img: diagram-architecture.svg]
├── 02 · Security Model      ← 02-security-model.md     [img: diagram-security-flow.svg]
├── 03 · Deployment (air-gap)← 03-deployment.md
├── 04 · Management Tool     ← 04-management-tool.md
├── 05 · Backup & Restore    ← 05-backup-restore.md
├── 06 · Monitoring          ← 06-monitoring.md         [img: diagram-monitoring.svg]
├── 07 · Client Integration  ← 07-client-integration.md
└── 08 · Reference           ← 08-reference.md
```

## Images

| Diagram | Used on page |
|---|---|
| `images/diagram-as-is-to-be.svg` | 00 · Overview |
| `images/diagram-architecture.svg` | 01 · Architecture |
| `images/diagram-security-flow.svg` | 02 · Security Model |
| `images/diagram-monitoring.svg` | 06 · Monitoring |

## Notes for uploading

- The `.md` files use relative image links like `images/diagram-*.svg`. When you
  paste into Confluence, replace them with the attached image (Confluence's
  **Insert → Image** after attaching the SVG to that page).
- Confluence Cloud / Data Center (recent versions) render **SVG** attachments. If your
  instance shows SVG poorly, open the SVG in a browser and export/screenshot to PNG,
  then attach the PNG instead (the diagrams are plain vector, so they scale cleanly).
- Tables and code blocks are standard Markdown / GitHub-flavored; Confluence's
  Markdown import handles them, or paste into a code macro where noted.
- Content is intentionally split so each page stays focused; cross-page links use the
  file names — repoint them to the corresponding Confluence page links after upload.
