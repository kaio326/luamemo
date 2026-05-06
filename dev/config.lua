-- dev/config.lua
-- Lapis database config for the dev container.
-- All values fall back to the docker-compose service names / credentials.

local config = require("lapis.config")

config("development", {
    postgres = {
        host     = os.getenv("PGHOST")     or "db",
        port     = tonumber(os.getenv("PGPORT")) or 5432,
        database = os.getenv("PGDATABASE") or "luamemo_dev",
        user     = os.getenv("PGUSER")     or "lapis",
        password = os.getenv("PGPASSWORD") or "lapis",
    },
    secret      = "dev-secret-change-me",
    num_workers = 1,
})
