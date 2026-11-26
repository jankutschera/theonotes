# Open-source notice for Theo Notes

Status: clause text for the app terms (EULA) and the website, written for True Brew Birdie Ltd.
It is not legal advice; have the lawyer check the final wording.

## Clause to reference from the app terms

> **Open-source components.** Theo Notes includes software that True Brew Birdie Ltd. did not
> write and that is licensed to you under its own open-source licence. The list of these
> components, with their licences, copyright notices and, where a licence asks for it, a link to
> their source code, is shown in the app under Theo Notes > About Theo Notes > Acknowledgements.
> For each such component its own licence applies, and where it conflicts with these terms, the
> component's licence prevails for that component. Nothing in these terms limits any right the
> component's licence gives you. The warranty and liability disclaimers of the component's
> authors and contributors apply to that component as its licence states; True Brew Birdie Ltd.
> gives no warranty on behalf of those authors, and they are not liable to you for it. If you
> pass a component on to others, you must keep its licence conditions in place.

## Why each part is there

- "Own licence prevails for that component": licences such as MIT, BSD, Apache-2.0 and the SIL
  Open Font License grant rights that these terms must not narrow, and Apple's standard App
  Store terms already make room for rights granted by open-source licences. Saying it outright
  removes any doubt.
- "Upstream disclaimers apply": many of these licences ask that the authors' warranty
  disclaimers and exclusion of liability stay in force. The clause does that, without changing
  what we promise for our own code.
- "Keep the conditions when passing on": the licences ask that later distribution of a
  component keeps their conditions.
- Link to the list: the Acknowledgements screen is where each notice, licence text and source
  link lives; it is generated from what ships (`scripts/gen-acknowledgements.py`), so it cannot
  drift from the app.

## Copyleft components

None ships today. The only one the editor used to reach, elkjs (EPL-2.0, through Mermaid's
optional ELK layout), was removed from the bundle so that the project can be licensed
GPL-3.0-only ( in `docs/decisions.md`). A new EPL or MPL component needs a ruling and,
for each, a source link in the Acknowledgements entry (the generator requires it).

## Open items

- Contact address for source requests: done 2026-10-27. hello@theonotes.app forwards to Jan via
  Cloudflare Email Routing; the Acknowledgements entry and the website footer name it.
- The app terms themselves do not exist yet; this clause is the text to put in them.
