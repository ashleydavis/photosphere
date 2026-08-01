//
// Rewrites a file in place, replacing everything matching a regular expression.
//
// scripts/update-mobile-media-tools.sh uses this to bump pinned versions inside build files. There is
// no portable shell answer: `sed -i` takes an argument on BSD/macOS that it rejects on GNU/Linux, and
// this script is run on both.
//
// The pattern is a JavaScript regular expression and the replacement uses JavaScript's syntax, so a
// capture group is referred to as $1. Nothing is written when the pattern matches nothing, so a
// pattern that has gone stale leaves the file alone rather than silently emptying it.
//
// Usage:
//   bun scripts/replace-in-file.ts --file <path> --pattern <regex> --replacement <text> [--flags <flags>]
//
// --flags defaults to "gm": every match, and ^/$ match at line boundaries, which is how the
// line-oriented tools this replaced behaved.
//

import { readFileSync, writeFileSync } from "node:fs";

//
// Reads a required `--name value` argument, failing loudly and naming it when absent.
//
function requiredArg(argv: string[], name: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        throw new Error(`Missing required argument --${name}`);
    }
    return argv[index + 1];
}

//
// Reads an optional `--name value` argument, returning the fallback when it is not present.
//
function optionalArg(argv: string[], name: string, fallback: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        return fallback;
    }
    return argv[index + 1];
}

const argv = process.argv.slice(2);
const filePath = requiredArg(argv, "file");
const pattern = new RegExp(requiredArg(argv, "pattern"), optionalArg(argv, "flags", "gm"));
const replacement = requiredArg(argv, "replacement");

const originalText = readFileSync(filePath, "utf8");
if (!pattern.test(originalText)) {
    throw new Error(`Pattern ${pattern} matched nothing in "${filePath}", so the file was left alone.`);
}

// test() advanced lastIndex on a global regex, so reset it before replacing.
pattern.lastIndex = 0;
writeFileSync(filePath, originalText.replace(pattern, replacement));
