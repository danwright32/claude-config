'use strict';
//
// The /pennie-dev-update registry: where it lives on a Mac, and the one reader of it
// (claude-config#1526).
//
// The registry lists the repositories the manager update covers, the GitHub account that reads each
// one, how each one deploys, and the date each one's changelog records start. It names WORK
// repositories, and this repository is public, so it is never tracked here. It is a file each Mac
// keeps for itself, named *.local.json, which claude-sync treats as one Mac's own file at any depth
// (LOCAL_FILE_GLOBS): a send never carries it and an apply never deletes it.
//
// It used to be the tracked payload/skills/pennie-dev-update/repos.json. claude-sync moves an
// installed copy of that file to this name before its mirror runs (MOVED_TO_LOCAL there), so a Mac
// that held the shared copy keeps its registry through the change.
//
// ONE home and ONE reader, asked by everything that reads it: the skill's gather.js and
// lint-post.js, and the merge gate hooks/require-changelog-tag.sh, which asks through this file's
// command line (`node dev-update-registry.js path|state <file>`). Two spellings of the path are two
// files the first time only one is moved (L83).
//
// The path is built from the HOME directory, never from where this file sits: the skill also runs
// from this repository's checkout, and a registry looked for beside the code there would be a file
// in the public repository's working tree.

const fs = require('fs');
const os = require('os');
const path = require('path');

const SKILL_DIR = path.join('.claude', 'skills', 'pennie-dev-update');
const FILE_NAME = 'repos.local.json';

function registryPath(home) {
  return path.join(home || os.homedir(), SKILL_DIR, FILE_NAME);
}

// What a person needs in front of them when the file is not there: where it goes, what it holds,
// and the deliberate way to gate nothing. Written once, here, so the gate and the skill say the
// same thing (L11).
function missingWhy(file) {
  return 'The dev update registry is not at ' + file + '. It is a file this Mac keeps for itself and '
    + 'is never sent to the shared config, because it names work repositories. Create it holding a '
    + 'JSON object with a "repos" list, one entry per repository the manager update covers, each '
    + 'giving the product name (name), the repository as owner/name (repo), the GitHub account that '
    + 'reads it (account), how it deploys (deployRecord), and the date its changelog records start '
    + '(changelogFrom). The skill\'s SKILL.md, under "The registry", shows an entry. To gate no '
    + 'repository on this Mac on purpose, write {"repos": []} in it.';
}

// The file, read and judged once. `state` is ok, missing or unreadable, and never anything else:
// a registry that exists and cannot be read is not one nobody wrote (L11, L98).
function readRegistry(file) {
  const where = file || registryPath();
  let text;
  try { text = fs.readFileSync(where, 'utf8'); }
  catch (e) {
    if (e.code === 'ENOENT') return { state: 'missing', file: where, why: missingWhy(where) };
    return { state: 'unreadable', file: where, why: 'The dev update registry at ' + where + ' could not be read (' + (e.code || e.message) + ').' };
  }
  let registry;
  try { registry = JSON.parse(text); }
  catch (e) {
    return { state: 'unreadable', file: where, why: 'The dev update registry at ' + where + ' is not valid JSON (' + e.message + ').' };
  }
  if (!registry || typeof registry !== 'object' || !Array.isArray(registry.repos)) {
    return { state: 'unreadable', file: where, why: 'The dev update registry at ' + where + ' does not hold a "repos" list.' };
  }
  return { state: 'ok', file: where, registry: registry };
}

module.exports = {
  registryPath: registryPath,
  readRegistry: readRegistry,
  missingWhy: missingWhy,
  FILE_NAME: FILE_NAME,
  SKILL_DIR: SKILL_DIR,
};

// The command line, for the merge gate, which is bash.
//   path          prints where the registry lives on this Mac
//   state [file]  prints {state, file, why} as JSON for that file (default: the one above)
if (require.main === module) {
  const cmd = process.argv[2];
  if (cmd === 'path') {
    process.stdout.write(registryPath() + '\n');
  } else if (cmd === 'state') {
    const got = readRegistry(process.argv[3] || registryPath());
    process.stdout.write(JSON.stringify({ state: got.state, file: got.file, why: got.why || '' }) + '\n');
  } else {
    process.stderr.write('Usage: dev-update-registry.js path | state [file]\n');
    process.exit(2);
  }
}
