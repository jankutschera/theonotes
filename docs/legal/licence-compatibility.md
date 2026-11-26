# Licence compatibility (project licence: GPL-3.0-only)

Status: working document, 2026-10-29 (stage-2 plan, task L1). Written by an engineering agent from the
sources named below. It is not legal advice; a lawyer reviews it before publication (plan items J1/J2).

**Rule enforced in code.** `scripts/gen-acknowledgements.py` calls `gplCompatible(spdx)` for every
licence that ships (npm packages in the editor bundle, SwiftPM packages, theme palettes, bundled
assets). `python3 -I scripts/gen-acknowledgements.py --check` fails when a verdict is "fail", or
"conditional" without what it needs.

| Verdict | Licences | What the gate demands |
|---|---|---|
| allowed | MIT, ISC, BSD-2-Clause, BSD-3-Clause, 0BSD, Zlib, Unlicense, CC0-1.0, BlueOak-1.0.0, Unicode-3.0, Apache-2.0 | nothing; keep the licence text and any NOTICE |
| conditional | OFL-1.1 (font data only) | a ruling id in the config entry (`"ruling": ""` for the two maths fonts) |
| conditional | MPL-2.0 | a ruling id in the package's `npmOverrides` entry, plus the existing source link and statement |
| conditional | EPL-2.0 | a ruling id **and** a filled-in Secondary-License notice (EPL-2.0 Exhibit A) naming the GPL, version 3 or later, in the package's licence file, NOTICE or README; otherwise the package must be removed |
| fail | GPL-2.0-only, GPL-3.0 as a dependency (outside, needs its own ruling), LGPL, AGPL, SSPL, CC-BY-SA, CC-BY-NC, EUPL, OSL, CPAL, RPL, anything unknown | none; the run stops |

Apache-2.0 is allowed because the project is GPL-3.0-only: Apache-2.0 is compatible with GPLv3 and
never with GPLv2. This is the reason the project is GPL-3.0-only and not "GPL-2.0-or-later".

## Verdicts per component (project GPL-3.0-only)

| Component | Licence | Verdict | Source / reason |
|---|---|---|---|
| **elkjs 0.9.3** (via Mermaid) | EPL-2.0 | **Was a blocker for a clean "GPL-3.0" claim; resolved by removal (L2). Not shipped.** | EPL-2.0 allows a GPL secondary licence only if the initial contributor attached the Exhibit A notice. Checked in `third_party/sources/elkjs-0.9.3.tgz`: `LICENSE.md` holds the empty Exhibit A template only, `lib/*.js` say `SPDX-License-Identifier: EPL-2.0`, `package.json` says `EPL-2.0`: no secondary licence. FSF list (fetched 2026-10-28, gnu.org/licenses/license-list.html#EPL2): "the EPL2 without this designation remains incompatible with the GPL". Shipping it as a separate unmodified file is arguable aggregation, but Mermaid loads it into the same JS program, so it was removed. Not verified: other elkjs releases, the upstream eclipse/elk repository; no lawyer opinion. |
| MathJax `@mathjax/src`, `mj-context-menu`, `speech-rule-engine`, `mhchemparser`, STIX2 font package | Apache-2.0 | OK for GPLv3 (not GPLv2, hence GPL-3.0-only is the right choice) | apache.org/licenses/GPL-compatibility.html (fetched 2026-10-28): Apache 2.0 "compatible with version 3 of the GPL", never with GPLv2; keep licence text and any NOTICE |
| chevrotain (+3 `@chevrotain/*`), DOMPurify (MPL-2.0 OR Apache-2.0, elected Apache-2.0), reflect-metadata (sync Worker) | Apache-2.0 | OK | same source |
| STIX Two math glyph data, Source Sans Pro-derived letters (inside the MathJax font package; also website fonts Atkinson Hyperlegible Next, Bricolage Grotesque, JetBrains Mono) | OFL-1.1 | OK as separate font data with licence text; low risk, LAWYER may confirm | FSF list: free licence for fonts, no GPL statement either way; fonts are data files loaded at runtime, not linked code; Reserved Font Names not used (`scripts/acknowledgements-config.json`, `docs/legal/fonts/README.md`). OFL FAQ on bundling with GPL software not re-fetched in this session (not verified). Gate: ruling id `` on both entries. |
| Mermaid 12.2.0 and the other MIT entries (CodeMirror 6, Lezer, KaTeX, dagre-d3-es, cytoscape*, roughjs, stylis, marked, dayjs, lodash-es, es-toolkit, uuid, khroma, Vite helper, theme palettes Catppuccin/Dracula/Everforest/Gruvbox/Nord/Rose Pine/Solarized/Tokyo Night, BIP39 word list) | MIT | OK | GPL-compatible; keep notices (generated, `Acknowledgements.json`) |
| d3 modules (19 ISC, 5 BSD-3-Clause) | ISC / BSD-3-Clause | OK | same |
| GRDB.swift 7.11.1, ZIPFoundation 0.9.20 | MIT | OK | SwiftPM `Package.resolved`, |
| Unicode emoji data and CLDR | Unicode-3.0 | OK | FSF list: "compatible with all versions of the GNU GPL" |
| robust-predicates (if bundled), 0BSD `tslib` (Worker) | Unlicense / 0BSD | OK | FSF list: Unlicense "compatible with the GNU GPL" |
| Private sync server runtime deps, not in the public repository (@simplewebauthn/server, aws4fetch, @peculiar/*, asn1js, tsyringe) | MIT / BSD-3 | OK (also for AGPL-3.0 if J6) | `package-lock.json` |
| Dev-only tools (vite, vitest, playwright, typescript, wrangler, miniflare; `sharp` with optional LGPL libvips inside miniflare, decisions.md:1183) | MIT / Apache-2.0 / LGPL optional | OK, not distributed; keep outside shipped bundles | not part of any artefact |
| Build-only tool `@anthropic-ai/mcpb` 2.1.2 (`tools/mcpb`, packs the Claude desktop extension) and its tree: 48 MIT, 4 ISC, 1 BlueOak-1.0.0, 1 MIT OR CC0-1.0, node-forge (BSD-3-Clause OR GPL-2.0, elected BSD-3-Clause) | MIT and the above | OK, not distributed: the extension holds only our manifest, icon and launcher | `tools/mcpb/pnpm-lock.yaml`, `pnpm --dir tools/mcpb licenses list` |
| SF Symbols (names in `Resources/tagcons.json`, rendered at runtime) | Apple SF Symbols licence | OK on Apple platforms; blocks a Windows/Android port and any export embedding the glyphs (audit F14) | system library, not in repo |
| Apple system frameworks, Swift runtime | Apple SDK | OK (GPLv3 system-library exception) | not bundled |
| Fonts, icon, images of the app | own / AI-generated icon | Not a licence conflict; ownership and trademark questions (F12) | `docs/brand/PROVENANCE.md` |

## Structural points (not dependency conflicts)

- Distribution through Apple's stores under Apple's terms is not possible for third parties under GPL;
  it works for Jan / True Brew Birdie Ltd. only as copyright holder (dual licensing). That needs one
  clear licensor and a CLA with relicensing rights for every outside contribution. Without the CLA the
  first merged outside PR blocks the App Store. VLC's historical GPL/App Store conflict is the known
  example (from memory, not re-verified).
- Much of the code was written by AI agents under Jan's direction; copyright in purely AI-generated
  code is uncertain in some jurisdictions. LAWYER question J1/J2.
- Mac v1 is a Developer ID download: the GPL source offer is the repo link in About (L5).

## What was and was not checked in task L1

- Checked by running it: `python3 -I scripts/gen-acknowledgements.py --check` passes on the tree
  (121 entries, no EPL-2.0 or MPL-2.0 entry; elkjs is out). The gate has tests with fixtures
  for each branch (`scripts/tests/test_gen_acknowledgements.py`): an EPL-2.0 package without a
  Secondary-License notice fails (also with the empty Exhibit A template and with a GPL-2.0-only
  notice), Apache-2.0 passes, OFL-1.1 needs a ruling id.
- The FSF and Apache statements above were fetched on 2026-10-28 by the plan author and were not
  fetched again in this task.
- Not verified: OFL FAQ statement on GPL bundling; other elkjs releases; the VLC example; any lawyer
  opinion.
- Proposed texts that belong to later tasks (CLA wording, trademark note) are not in this file; they are
  written in L4.
