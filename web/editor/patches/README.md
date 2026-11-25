# CodeMirror autocomplete composition patch

`@codemirror__autocomplete@6.20.4.patch` patches the exact pinned dependency;
it does not upgrade CodeMirror. pnpm applies it through the adjacent
`pnpm-workspace.yaml` configuration and the lockfile's patch hash.

On iOS, CodeMirror can defer reading a composition deletion until an animation
frame. Autocomplete's fixed 20 ms composition-end transaction could arrive first,
discard the pending DOM mutations and restore the canceled text. The patch waits
for a frame and then a task before dispatching, retaining the 20 ms delay. Both
the ESM and CommonJS builds carry the same change.

When upgrading `@codemirror/autocomplete`, review its composition-end handler and
the corresponding `@codemirror/view` observer behavior. Rebase or remove this
patch only after the slowed-frame `e2e/ime.spec.ts` cancellation cases pass
against the replacement, and repeat actual Japanese software-key acceptance.
Do not silently drop the patch to resolve an installation conflict. A frozen
pnpm installation must retain the patch configuration and matching lock hash.

The diagnosis and native before-fix evidence are recorded in
`docs/ios-accessibility-acceptance.md` at the repository root.
