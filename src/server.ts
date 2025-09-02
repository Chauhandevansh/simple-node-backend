import "dotenv/config"; // load .env early
import { buildApp } from "./app";
import { loadEnv } from "./config/env";
import { logger } from "./lib/logger";

const env = loadEnv();
const app = buildApp();

app.listen(env.PORT,'0.0.0.0', () => {
  logger.info({ port: env.PORT, env: env.NODE_ENV }, "server started");
});
