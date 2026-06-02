import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      // server-only throws outside RSC; stub it for tests.
      "server-only": path.resolve(__dirname, "test/stubs/server-only.ts"),
      "@": path.resolve(__dirname, "src"),
    },
  },
  test: {
    environment: "node",
    globals: true,
    setupFiles: ["./test/setup.ts"],
    // Tests share one Postgres database, so run them serially.
    fileParallelism: false,
    sequence: { concurrent: false },
    hookTimeout: 30000,
    testTimeout: 30000,
  },
});
