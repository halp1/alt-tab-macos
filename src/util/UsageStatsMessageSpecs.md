# UsageStats — Specs

> **Line coverage:** `UsageStatsTestable.swift` · _refreshed after Pro removal_

## Summary

`UsageStats` records each switcher summon so the About window can show weekly / monthly / yearly
use counts. `UsageStatsTestable.formatCount` formats those counts for display.

## Test scenarios

Mirrors `UsageStatsMessageTests.swift` 1:1.

- **testFormatCount_thousandSeparator** — large counts render with thousand separators.
