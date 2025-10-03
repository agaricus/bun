/**
 * Mimics https://github.com/npm/hosted-git-info/blob/main/test/parse-url.js
 */
import { describe, expect, it } from "bun:test";
import { hostedGitInfo } from "bun:internal-for-testing";

const okCases = [
  'git+ssh://git@abc:frontend/utils.git#6d45447e0c5eb6cd2e3edf05a8c5a9bb81950c79',
  'file:../../../global-prefix/lib/node_modules/@myscope/bar',
];

describe("parseUrl", () => {
  it.each(okCases)("parses %s", (url) => {
    expect(hostedGitInfo.parseUrl(url)).not.toBeNull();
    });
});
