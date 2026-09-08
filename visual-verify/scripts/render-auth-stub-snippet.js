#!/usr/bin/env node
// render-auth-stub-snippet.js <validated-config.json>
//
// Reads a config already validated "valid" by scripts/auth-stub.sh (the
// object at its .config field) and prints a JS snippet for Phase 3 of
// skills/verify/SKILL.md's "Auth-stub injection (opt-in)" section to embed
// into the Playwright driver script, before page.goto().
//
// Every config-controlled value reaches the generated driver script the same
// way: as a JSON.stringify()-produced literal assigned to a local variable
// (intercept.url_pattern / intercept.content_type / the single dataArg
// envelope), which the fixed, hardcoded call sites below then reference by
// name. JSON.stringify() always produces syntactically valid, self-contained
// JS literal syntax (every quote/backslash/control character correctly
// escaped) -- safe to appear as an expression in the generated file, exactly
// like any JSON literal is also valid JS object/array-literal syntax.
// What actually matters, and what genuinely never varies across configs, is
// fn's OWN source text (the function passed to page.addInitScript below):
// no config-controlled value is ever concatenated into fn's own function
// body -- only received by it as a runtime argument -- which is what
// prevents a config value from ever executing as arbitrary in-page code.
'use strict';
const fs = require('fs');

const configPath = process.argv[2];
if (!configPath) {
  console.error('usage: render-auth-stub-snippet.js <validated-config.json>');
  process.exit(1);
}
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

const stubTriples = Object.keys(config.stub).map((name) => {
  const entry = config.stub[name];
  return {
    name,
    type: entry.type,
    value: Object.prototype.hasOwnProperty.call(entry, 'value') ? entry.value : null,
  };
});

const dataArg = {
  global_object_path: config.global_object_path,
  factory_method: config.factory_method,
  stub_triples: stubTriples,
  permission_keys_by_route: config.permission_keys_by_route,
};

const urlPatternLiteral = JSON.stringify(config.intercept.url_pattern);
const contentTypeLiteral = JSON.stringify(config.intercept.content_type);
const dataArgLiteral = JSON.stringify(dataArg);

const snippet = `
// --- visual-verify auth-stub injection (opt-in) ---
const __vvUrlPattern = ${urlPatternLiteral};
const __vvContentType = ${contentTypeLiteral};
// Both page.route() and page.addInitScript() below return Promises that must
// resolve BEFORE the driver script's subsequent page.goto() -- without
// awaiting, page.goto() can begin before the interception/init-script
// registration actually completes, meaning the stub may silently not apply
// on the very first navigation, defeating the entire point of registering it
// "before" navigating. This requires the emitted snippet to run inside an
// async context (see skills/verify/SKILL.md's Phase 3 driver-script
// instructions, which frame the whole script body as an async IIFE for
// exactly this reason).
await page.route(__vvUrlPattern, (route) => route.fulfill({ status: 200, contentType: __vvContentType, body: '' }));

const __vvDataArg = ${dataArgLiteral};
await page.addInitScript((dataArg) => {
  function resolveValue(v, ctx) {
    if (v === '$PERMISSION_KEYS') return ctx.permissionKeys;
    if (v === '$ORIGIN_PATHNAME') return ctx.originPathname;
    if (Array.isArray(v)) return v.map((x) => resolveValue(x, ctx));
    if (v !== null && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v)) out[k] = resolveValue(v[k], ctx);
      return out;
    }
    return v;
  }

  const rawPathname = location.pathname;
  const normalized = rawPathname.length > 1 ? rawPathname.replace(/\\/+$/, '') : rawPathname;
  const routeMap = dataArg.permission_keys_by_route;
  let permissionKeys;
  let matchKind;
  if (Object.prototype.hasOwnProperty.call(routeMap, normalized)) {
    permissionKeys = routeMap[normalized];
    matchKind = 'exact';
  } else {
    permissionKeys = routeMap['*'];
    matchKind = 'fallback';
  }
  const ctx = { permissionKeys, originPathname: location.origin + rawPathname };

  let target = globalThis;
  const pathSegs = dataArg.global_object_path;
  for (let i = 0; i < pathSegs.length - 1; i++) {
    const seg = pathSegs[i];
    if (typeof target[seg] !== 'object' || target[seg] === null) target[seg] = {};
    target = target[seg];
  }
  const leaf = pathSegs[pathSegs.length - 1];
  if (typeof target[leaf] !== 'object' || target[leaf] === null) target[leaf] = {};
  const sdkObj = target[leaf];

  sdkObj[dataArg.factory_method] = function () {
    const impl = {};
    for (const triple of dataArg.stub_triples) {
      if (triple.type === 'noop') {
        impl[triple.name] = function () {};
      } else if (triple.type === 'noop_return') {
        const resolved = resolveValue(triple.value, ctx);
        impl[triple.name] = function () { return resolved; };
      } else if (triple.type === 'async_const') {
        const resolved = resolveValue(triple.value, ctx);
        impl[triple.name] = function () { return Promise.resolve(resolved); };
      }
    }
    return impl;
  };
  sdkObj.__visualVerifyPermissionKeyMatch = matchKind;
}, __vvDataArg);
// --- end auth-stub injection ---
`;

process.stdout.write(snippet);
