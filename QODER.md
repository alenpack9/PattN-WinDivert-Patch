# QODER.md

## Language and text direction

- Documentation, commit summaries, plans, and walkthroughs in this repo are written in Persian (Farsi).
- Wrap every Persian section in `<div dir="rtl">` and `</div>`, with a blank line after the opening tag and before the closing tag, so headings, lists, and code blocks still parse.
- Never wrap inline code, identifiers, paths, or terminal commands in RTL markers; they render LTR on their own and must stay byte-exact.
- GitHub strips `<div>` in rendered Markdown, so RTL inside README/Issue/PR views depends on the viewer. Do not rely on `<div>` alone to fix layout on GitHub; avoid mixing Persian and LTR tokens in a single line when ambiguity matters.

## Project facts

- Purpose: patch and build toolkit that injects the WinDivert engine plus a Connect/Disconnect toggle into PattN.
- Patch logic: `Apply-WinDivert.ps1`. Local build entry: `PattN-WinDivert-Build.bat` (asks for the PattN source path).
- CI: `.github/workflows/auto-sync-and-build.yml` polls `patterniha/PattN` branch `my-releases` every 10 minutes, builds self-contained .NET 10, pushes patched source to `alenpack9/WinDivert`, and publishes a release.
- Upstream state is tracked in `last_upstream_commit.txt`; keep it updated whenever the polled commit advances.
- Core binaries and the geo database are downloaded by `scripts/Ensure-Cores.ps1` and are not committed (`bin/` is ignored), along with `*.rar`, `*.zip`, and build outputs.
- Do not commit build artifacts, archives, or generated `PattN/` and `upstream-PattN/` trees.
