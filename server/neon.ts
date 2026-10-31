import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  functions: {
    plugdb: {
      name: "AG PlugFinder plugin database",
      source: "src/index.ts",
      env: { UPLOAD_KEY: process.env.UPLOAD_KEY! },
    },
  },
});
