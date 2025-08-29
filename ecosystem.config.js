/* eslint-env node */
module.exports = {
  apps: [{
    name: "simple-node-backend",
    script: "dist/server.js",
    env: { NODE_ENV: "production" }
  }]
};
