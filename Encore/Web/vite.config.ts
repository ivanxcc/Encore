import { defineConfig } from "vite";
import preact from "@preact/preset-vite";

// Built into the relay's binary (Encore/Relay/cmd/encore-relay/web), which serves it.
export default defineConfig({
  plugins: [preact()],
  build: { target: "es2020", outDir: "dist", assetsInlineLimit: 0, chunkSizeWarningLimit: 700 },
  server: { proxy: { "/v1": "http://127.0.0.1:8089", "/config.json": "http://127.0.0.1:8089" } },
});
