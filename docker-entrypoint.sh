#!/bin/sh
set -e

echo "Running migrations..."
./bin/norns eval "Norns.Release.migrate()"
echo "Migrations complete."

echo "Starting Norns on port ${PORT}..."
exec ./bin/norns start
