/* eslint-env node */
module.exports = {
  apps: [{
    name: "simple-node-backend",
    script: "current/dist/server.js", // use symlink
    env: { NODE_ENV: "production" }
  }]
};
