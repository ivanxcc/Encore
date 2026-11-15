import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// Built into the relay's binary (Encore/Relay/cmd/encore-relay/web), which serves it.
// A short version for Settings: the build's date and, in CI, its commit.
const build = new Date().toISOString().slice(0, 10) + (process.env.GITHUB_SHA ? " · " + process.env.GITHUB_SHA.slice(0, 7) : "");

export default defineConfig({
  plugins: [preact()],
  define: { __BUILD__: JSON.stringify(build) },
  build: { target: "es2020", outDir: "dist", assetsInlineLimit: 0, chunkSizeWarningLimit: 700 },
  server: { proxy: { "/v1": "http://127.0.0.1:8089", "/config.json": "http://127.0.0.1:8089" } },
});
