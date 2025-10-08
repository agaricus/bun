// Test script to verify URL parsing for new fields
const { iniInternals } = require("bun:internal-for-testing");

const testCases = [
  "//registry.npmjs.org/:cafile=/path/to/ca.pem",
  "//registry.npmjs.org/:certfile=/path/to/cert.crt",
  "//registry.npmjs.org/:keyfile=/path/to/key.pem",
  "//registry.npmjs.org/:cafile=/ca.pem\n//registry.npmjs.org/:certfile=/cert.crt\n//registry.npmjs.org/:keyfile=/key.pem",
];

for (const testCase of testCases) {
  console.log(`Testing: ${testCase.replace("\n", "\\n")}`);
  try {
    const result = iniInternals.loadNpmrc(testCase);
    console.log(`  cafile: ${result.default_registry_cafile}`);
    console.log(`  certfile: ${result.default_registry_certfile}`);
    console.log(`  keyfile: ${result.default_registry_keyfile}`);
  } catch (e) {
    console.log(`  Error: ${e.message}`);
  }
  console.log();
}
