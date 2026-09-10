# Lessons

- Keep backend-specific CLI command construction and metadata SQL in one connector file per database; retain a small adapter module only for shared dispatch and output normalization.
- After removing a Lua function, immediately run a module-load check so unmatched block delimiters cannot escape focused tests.
- Use a command-line progress counter for periodic feedback; notification replacement is provider-specific and can stack toasts.
- Confirm established user-facing defaults before changing them; do not infer a keybinding scheme from a reported missing mapping.
- When a rebrand request is ambiguous, confirm whether public-only or full-namespace scope is intended before changing names.
- Verify unfamiliar Nerd Font glyph names against the glyph map before changing a user-facing icon.
- For UI-parity work, model the hierarchy shown in the reference rather than reducing it to top-level items; a SQL structure view includes internal query elements, not only statements.
- For navigable trees, settle initial expansion and repeated-clause behavior explicitly; SQL set-operation branches are distinct outline nodes while deeper parenthesized subqueries are not peers.
- Group a cohesive family of new display controls under one configuration object instead of expanding the top-level setup API with parallel fields.
- For README connector additions, verify the requested profile object is complete and visibly placed in the rendered connector details, not merely described elsewhere.
- In README requirement tables, name and link each required CLI explicitly so the dependency is as visible as the surrounding entries.
- When a screenshot is paired with an exact desired row, implement that literal output before generalizing the visual pattern to sibling rows.
- When a safer transport has fidelity tradeoffs, preserve the existing transport as an explicit profile choice instead of forcing every user onto one representation.
