/* eslint-env node */
module.exports = {
  apps: [
    {
      name: "simple-node-backend",
      script: "./dist/server.js",
      cwd: "/opt/apps/simple-node-backend/current",
      env: require("dotenv").config({ path: "/opt/apps/simple-node-backend/current/.env" }).parsed
    }
  ]
};

