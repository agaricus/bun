import { describe, expect, it } from "bun:test";
import { hostedGitInfo } from "bun:internal-for-testing";
import { validGitUrls, invalidGitUrls } from "./cases";

describe("fromUrl", () => {
  describe("valid urls", () => {
    describe.each(Object.entries(validGitUrls))("%s", (_, urlset: object) => {
      it.each(Object.entries(urlset))("parses %s", (url, expected) => {
        expect(hostedGitInfo.fromUrl(url)).toEqual(expected);
      });
    });
  });

  describe("invalid urls", () => {
  });
});
