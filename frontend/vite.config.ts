import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig(({ command }) => ({
  // Production build → assets served at /static/ (FastAPI mounts the
  // packed dist/ there; the platform's Cloudflare cache rule pins
  // /static/assets/* for 1 year). Dev → root, so localhost:5173 works.
  base: command === "build" ? "/static/" : "/",

  plugins: [react(), tailwindcss()],

  server: {
    host: "0.0.0.0",
    port: 5173,
    // /api/* requests get proxied to the FastAPI backend running in the
    // sibling container. App code calls fetch('/api/...') — same in dev,
    // production, and tests.
    proxy: {
      "/api": {
        target: "http://backend:8000",
        changeOrigin: true,
      },
    },
    // Polling watcher works reliably across Docker bind mounts.
    watch: {
      usePolling: true,
      interval: 500,
    },
  },
}));
