# SANETRA VISUALIZATION STYLE GUIDE

- **Background:** Pure white (`#FFFFFF`) figure and plot canvas.
- **Typography:** Clean sans-serif (`Segoe UI` / `DejaVu Sans` / `Arial`), near-black titles (`#111827`), dark slate labels (`#1F2937`).
- **Palette:** Restrained Navy (`#0F2942`), Steel Blue (`#2563EB`), Teal (`#0D9488`), Slate (`#64748B`), Muted Amber (`#D97706`), and Muted Crimson (`#DC2626` for error/CER only).
- **Layout:** `constrained_layout=True`, unified `fig.suptitle()` on multi-panel charts, zero top/right spines, subtle `#E5E7EB` gridlines, `ylim` headroom >= 18% above max bar height.
- **Confusion Matrices:** Square cells (`aspect='equal'`), explicit sample support on Y-axis labels, raw counts in raw matrices, row-normalized percentages + counts in normalized matrices, labeled colorbar.
- **Exports:** 300 DPI PNG, vector PDF, and SVG for every figure.
