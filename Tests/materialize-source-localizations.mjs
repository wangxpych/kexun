import fs from 'node:fs';

// Generated catalog normalization: ship the source language as a real resource
// rather than relying solely on the source-code fallback. Preserve positional
// format placeholders and all existing translations supplied by Xcode.
const path = process.argv[2];
if (!path) throw new Error('Expected an xcstrings path');
const catalog = JSON.parse(fs.readFileSync(path, 'utf8'));
for (const [key, entry] of Object.entries(catalog.strings)) {
  if (entry.shouldTranslate === false) continue;
  entry.localizations ??= {};
  const source = entry.localizations[catalog.sourceLanguage] ??= {};
  if (!source.stringUnit && !source.variations && !source.substitutions) {
    source.stringUnit = { state: 'translated', value: key };
  } else if (source.stringUnit) {
    source.stringUnit.state = 'translated';
  }
}
fs.writeFileSync(path, `${JSON.stringify(catalog, null, 2)}\n`);
