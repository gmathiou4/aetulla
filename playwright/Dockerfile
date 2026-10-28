# Playwright server, built so the version is baked in at build time: nothing is
# downloaded at runtime (the old `npx -y playwright@X run-server` needed network on
# every container start, and its version lived in the run command, not the image).
# PLAYWRIGHT_VERSION comes from the compose build arg; it is the ONLY place the
# version is written in this repo (see x-playwright-version in docker-compose.yml).
ARG PLAYWRIGHT_VERSION
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble
ARG PLAYWRIGHT_VERSION
RUN : "${PLAYWRIGHT_VERSION:?build arg PLAYWRIGHT_VERSION is required}" \
    && npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
    && npm cache clean --force
# Lets bin/aetulla read the version back from a running container.
ENV PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION}
EXPOSE 3000
CMD ["playwright", "run-server", "--port", "3000", "--host", "0.0.0.0"]
